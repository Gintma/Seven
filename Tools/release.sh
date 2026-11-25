#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source "$project_dir/Tools/signing.sh"

fail() {
  print -u2 -- "$1"
  exit 1
}

make_dmg=false
case "${1:-}" in
  '')
    (( $# == 0 )) || fail "用法：./Tools/release.sh [--dmg]"
    ;;
  --dmg)
    (( $# == 1 )) || fail "用法：./Tools/release.sh [--dmg]"
    make_dmg=true
    ;;
  -h|--help)
    print "用法：./Tools/release.sh [--dmg]"
    print "需要可用的 Developer ID Application 证书、SEVEN_NOTARY_PROFILE 和 Sparkle 签名密钥。"
    exit 0
    ;;
  *) fail "用法：./Tools/release.sh [--dmg]" ;;
esac

cd "$project_dir"
identity_record="$(find_signing_identity "${SEVEN_SIGN_IDENTITY:-}" true)"
[[ -n "$identity_record" ]] || fail "缺少可用的 Developer ID Application 签名身份。请安装证书与私钥，或检查 SEVEN_SIGN_IDENTITY。"
IFS=$'\t' read -r signing_identity _ <<< "$identity_record"
[[ -n "${SEVEN_NOTARY_PROFILE:-}" ]] || fail "缺少 SEVEN_NOTARY_PROFILE。请先运行 xcrun notarytool store-credentials 并设置钥匙串配置名。"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Info.plist 2>/dev/null)" ||
  fail "Info.plist 缺少 SUPublicEDKey。请填入 Sparkle 的公开签名密钥。"
[[ "$public_key" =~ '^[A-Za-z0-9+/]{43}=$' ]] ||
  fail "请将 Sparkle generate_keys 输出的公钥填入 Info.plist 的 SUPublicEDKey。"
[[ "$version" =~ '^[0-9]+(\.[0-9]+){1,2}$' && "$build" =~ '^[0-9]+$' ]] ||
  fail "请在 Info.plist 中设置数字版本号及递增的整数构建号。"
destination="$project_dir/dist/v$version"
[[ ! -e "$destination" ]] || fail "dist/v$version 已存在。请先移出已有产物，再重试发布。"

swift package resolve
sparkle_tools="$project_dir/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$sparkle_tools/sign_update" && -x "$sparkle_tools/generate_keys" ]] ||
  fail "SwiftPM 的 Sparkle 工具未找到，请检查依赖下载。"
key_account="${SEVEN_SPARKLE_KEY_ACCOUNT:-seven}"
if ! keychain_public_key="$("$sparkle_tools/generate_keys" --account "$key_account" -p)"; then
  fail "钥匙串缺少 Sparkle 签名密钥。请先运行 generate_keys --account seven，或设置 SEVEN_SPARKLE_KEY_ACCOUNT 使用已有密钥。"
fi
[[ "$keychain_public_key" == "$public_key" ]] ||
  fail "Sparkle 钥匙串密钥与 Info.plist 的 SUPublicEDKey 不匹配。"

stage_dir="$(mktemp -d "$project_dir/.build/seven-release.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
mkdir -p "$stage_dir/output"
app="$stage_dir/Seven.app"
zip="$stage_dir/output/Seven-$version.zip"

notarize() {
  local archive="$1"
  local result="$stage_dir/notary.plist"
  local submission_status submission_id
  if ! xcrun notarytool submit "$archive" --wait --keychain-profile "$SEVEN_NOTARY_PROFILE" \
       --output-format plist > "$result"; then
    fail "公证提交失败。请检查 SEVEN_NOTARY_PROFILE、Apple 返回的错误及网络连接。"
  fi
  submission_status="$(plutil -extract status raw -o - "$result")"
  submission_id="$(plutil -extract id raw -o - "$result")"
  [[ "$submission_status" == Accepted ]] ||
    fail "Apple 公证状态为 $submission_status。请使用 xcrun notarytool log $submission_id 查看详情。"
}

SEVEN_SIGN_IDENTITY="$signing_identity" ./build-app.sh release --universal
ditto Seven.app "$app"
# Apple 可接收 ZIP，但票据贴在 app 上。最终 ZIP 用粘贴票据后的 app 重打。
ditto -c -k --keepParent "$app" "$stage_dir/notarization.zip"
notarize "$stage_dir/notarization.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
ditto -c -k --keepParent "$app" "$zip"

if [[ "$make_dmg" == true ]]; then
  mkdir "$stage_dir/disk"
  ditto "$app" "$stage_dir/disk/Seven.app"
  ln -s /Applications "$stage_dir/disk/Applications"
  dmg="$stage_dir/output/Seven-$version.dmg"
  hdiutil create -volname Seven -srcfolder "$stage_dir/disk" -format UDZO "$dmg"
  codesign --sign "$signing_identity" --timestamp "$dmg"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi

if ! signature="$("$sparkle_tools/sign_update" --account "$key_account" -p "$zip")"; then
  fail "Sparkle ZIP 签名失败。请检查钥匙串中的签名私钥及访问权限。"
fi
[[ "$signature" =~ '^[A-Za-z0-9+/]{86}==$' ]] || fail "Sparkle 未返回有效的 EdDSA 签名。"
"$sparkle_tools/sign_update" --account "$key_account" --verify "$zip" "$signature"

/usr/bin/python3 - "$version" "$build" "$minimum_system" "$zip" "$signature" "$stage_dir/appcast.xml" <<'PY'
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

version, build, minimum_system, archive, signature, output = sys.argv[1:]
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle)
tree = ET.parse("appcast.xml", parser=ET.XMLParser(target=ET.TreeBuilder(insert_comments=True)))
channel = tree.find("channel")
if channel is None:
    raise SystemExit("appcast.xml 缺少 RSS channel。")

existing_builds = [item.findtext(f"{{{sparkle}}}version") for item in channel.findall("item")]
if any(previous is None or not previous.isascii() or not previous.isdecimal() for previous in existing_builds):
    raise SystemExit("appcast.xml 存在无法比较的构建号。")
if any(int(previous) >= int(build) for previous in existing_builds):
    raise SystemExit("CFBundleVersion 必须大于 appcast.xml 中的所有已有构建号。")
if any(item.findtext(f"{{{sparkle}}}shortVersionString") == version for item in channel.findall("item")):
    raise SystemExit("该版本已在 appcast.xml 中发布。请设置新的 CFBundleShortVersionString。")

release_url = f"https://github.com/Gintma/Seven/releases"
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Seven {version}"
ET.SubElement(item, "link").text = f"{release_url}/tag/v{version}"
ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
ET.SubElement(item, f"{{{sparkle}}}version").text = build
ET.SubElement(item, f"{{{sparkle}}}shortVersionString").text = version
ET.SubElement(item, f"{{{sparkle}}}minimumSystemVersion").text = minimum_system
zip_path = Path(archive)
ET.SubElement(item, "enclosure", {
    "url": f"{release_url}/download/v{version}/{zip_path.name}",
    f"{{{sparkle}}}edSignature": signature,
    "length": str(zip_path.stat().st_size),
    "type": "application/octet-stream",
})
first_existing = channel.find("item")
if first_existing is not item:
    channel.remove(item)
    channel.insert(list(channel).index(first_existing), item)
ET.indent(tree, space="  ")
tree.write(output, encoding="utf-8", xml_declaration=True)
PY

mkdir -p "$project_dir/dist"
mv "$stage_dir/output" "$destination"
mv "$stage_dir/appcast.xml" "$project_dir/appcast.xml"
print "发布产物位于 dist/v$version。请将产物上传到 GitHub Release v$version，再提交 appcast.xml。"
