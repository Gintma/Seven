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
# actool 同时生成 macOS 26 的分层图标以及 macOS 14/15 的扁平回退图标。
compiled_assets="$tmp_dir/compiled"
mkdir -p "$compiled_assets"
xcrun actool "$project_dir/Resources/AppIcon.icon" "$project_dir/Resources/Assets.xcassets" \
  "$project_dir/Resources/Symbols.xcassets" --compile "$compiled_assets" \
  --platform macosx --minimum-deployment-target 14.0 \
  --product-type com.apple.product-type.application --app-icon AppIcon \
  --output-partial-info-plist "$tmp_dir/assets.plist" --errors --warnings \
  --output-format human-readable-text
if [[ ! -s "$compiled_assets/Assets.car" || ! -s "$compiled_assets/AppIcon.icns" ]]; then
  print -u2 "actool 未生成应用图标，请使用 Xcode 26 或更新版本。"
  exit 1
fi
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
cp "$compiled_assets/Assets.car" "$compiled_assets/AppIcon.icns" "$app/Contents/Resources/"
cp "$project_dir/Sources/Seven/Art/Shiba.usdz" "$app/Contents/Resources/"
# (N) 允许某类文件为空，避免 zsh 报 no matches found；总数为 0 时才视为错误。
brand_icons=("$project_dir/Resources/BrandIcons/"*.(png|svg)(N))
if (( ${#brand_icons} == 0 )); then
  print -u2 "No brand icons found in Resources/BrandIcons."
  exit 1
fi
cp "${brand_icons[@]}" "$app/Contents/Resources/BrandIcons/"
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
