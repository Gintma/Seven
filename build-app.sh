#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
configuration="release"
variant=""
usage() {
  print -u2 "用法：./build-app.sh [release|debug] [--variant <name>]"
  exit 2
}
if (( $# > 0 )) && [[ "$1" != "--variant" ]]; then
  configuration="$1"
  shift
fi
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
  usage
fi
if (( $# > 0 )); then
  [[ "$1" == "--variant" && $# == 2 ]] || usage
  variant="$2"
  if [[ ! "$variant" =~ '^[a-z0-9-]+$' ]]; then
    print -u2 "变体名只能包含小写字母、数字和连字符，且不能为空。"
    exit 2
  fi
fi
app_name="Seven"
bundle_identifier="local.seven.translator"
if [[ -n "$variant" ]]; then
  app_name+="-$variant"
  bundle_identifier+=".$variant"
fi
# 变体仍共享系统全局快捷键：同时注册时 HotKeyManager 显示已被占用，属预期。
# SMAppService 开机启动同一时间只能注册一个变体。
signing_dir="$HOME/Library/Application Support/Seven/BuildSigning"
signing_keychain="$signing_dir/SevenBuild.keychain-db"
signing_password_file="$signing_dir/keychain-password"

cd "$project_dir"
# 签名前置条件缺失时先退出，避免覆盖现有可试用的包。
if [[ ! -f "$signing_keychain" || ! -f "$signing_password_file" ]]; then
  print -u2 "Local signing is not configured. Run ./setup-local-signing.sh once."
  exit 1
fi
# 变体是开发试用渠道；优化级别与诊断入口的可见性分开控制。
build_arguments=(-c "$configuration")
if [[ -n "$variant" ]]; then
  build_arguments+=(-Xswiftc -DSEVEN_DEVELOPMENT)
fi
swift build "${build_arguments[@]}"

app="$project_dir/$app_name.app"
binary="$project_dir/.build/$configuration/Seven"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/seven-build.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
iconset="$tmp_dir/AppIcon.iconset"
master_icon="$project_dir/Resources/Seven.png"
mkdir -p "$iconset"
sips -z 16 16 "$master_icon" --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$master_icon" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$master_icon" --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$master_icon" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$master_icon" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$master_icon" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$master_icon" --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$master_icon" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$master_icon" --out "$iconset/icon_512x512.png" >/dev/null
cp "$master_icon" "$iconset/icon_512x512@2x.png"
iconutil -c icns "$iconset" -o "$tmp_dir/AppIcon.icns"
# 每次重建可执行文件与资源目录，重命名之前的二进制和已删除资源都不会残留。
rm -rf "$app/Contents/MacOS" "$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/BrandIcons"
cp "$binary" "$app/Contents/MacOS/Seven"
cp "$project_dir/Info.plist" "$app/Contents/Info.plist"
if [[ -n "$variant" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$app/Contents/Info.plist"
fi
for localization in "$project_dir/Sources/Seven/Localization/"*.lproj; do
  cp -R "$localization" "$app/Contents/Resources/"
done
cp "$tmp_dir/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$project_dir/Sources/Seven/Art/Shiba.usdz" "$app/Contents/Resources/"
# (N) 允许某类文件为空，避免 zsh 报 no matches found；总数为 0 时才视为错误。
brand_icons=("$project_dir/Resources/BrandIcons/"*.(png|svg)(N))
if (( ${#brand_icons} == 0 )); then
  print -u2 "No brand icons found in Resources/BrandIcons."
  exit 1
fi
cp "${brand_icons[@]}" "$app/Contents/Resources/BrandIcons/"
# 界面资源和自定义 SF 符号一起编译为 Assets.car，随后统一签名。
symbols_plist="$tmp_dir/symbols.plist"
xcrun actool "$project_dir/Resources/Assets.xcassets" "$project_dir/Resources/Symbols.xcassets" \
  --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 \
  --output-partial-info-plist "$symbols_plist" --errors --warnings >/dev/null
chmod 755 "$app/Contents/MacOS/Seven"
signing_password="$(<"$signing_password_file")"
security unlock-keychain -p "$signing_password" "$signing_keychain"
signing_identity="$(security find-certificate -a -Z -c 'Seven Local Development' "$signing_keychain" | awk '/SHA-1 hash:/ { print $3; exit }')"
if [[ -z "$signing_identity" ]]; then
  print -u2 "The Seven local signing identity is unavailable. Run ./setup-local-signing.sh again."
  exit 1
fi
codesign --force --deep \
  --sign "$signing_identity" \
  --keychain "$signing_keychain" \
  --identifier "$bundle_identifier" \
  "$app"
codesign --verify --deep --strict --verbose=2 "$app"
print "$app"
