#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
source "$project_dir/Tools/signing.sh"

configuration="release"
variant=""
universal=false
local_signing=false
usage() {
  print -u2 "用法：./build-app.sh [release|debug] [--variant <name>] [--universal] [--local-signing]"
  exit 2
}
if (( $# > 0 )) && [[ "$1" == release || "$1" == debug ]]; then
  configuration="$1"
  shift
fi
while (( $# > 0 )); do
  case "$1" in
    --variant)
      (( $# >= 2 )) || usage
      [[ -z "$variant" && "$2" =~ '^[a-z0-9-]+$' ]] || usage
      variant="$2"
      shift
      ;;
    --universal) universal=true ;;
    --local-signing) local_signing=true ;;
    *) usage ;;
  esac
  shift
done

cd "$project_dir"
mkdir -p "$project_dir/.build"
zmodload zsh/system
build_lock="$project_dir/.build/seven-build.lock"
: >> "$build_lock"
if ! zsystem flock -t 0 "$build_lock"; then
  print -u2 "已有打包任务在此 worktree 运行。"
  exit 1
fi

output_dir="${SEVEN_BUILD_OUTPUT_DIR:-$project_dir}"
if [[ ! -d "$output_dir" ]]; then
  print -u2 "打包输出目录不存在。"
  exit 1
fi
output_dir="${output_dir:A}"
app_name="Seven"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)"
if [[ -n "$variant" ]]; then
  app_name+="-$variant"
  bundle_identifier+=".$variant"
fi
# 签名凭证缺失时先退出，保留原有的试用包。
signing_arguments=(--force)
identity_record=""
release_signing=false
if [[ -n "${SEVEN_SIGN_IDENTITY:-}" ]]; then
  identity_record="$(find_signing_identity "$SEVEN_SIGN_IDENTITY")"
  if [[ -z "$identity_record" ]]; then
    print -u2 "未找到 SEVEN_SIGN_IDENTITY 指定的可用签名身份。请检查证书及其私钥。"
    exit 1
  fi
elif [[ "$local_signing" == false ]]; then
  identity_record="$(find_signing_identity "" true)"
fi

if [[ -n "$identity_record" ]]; then
  IFS=$'\t' read -r signing_identity identity_name <<< "$identity_record"
  [[ "$identity_name" != "Developer ID Application:"* ]] || release_signing=true
  case "$identity_name" in
    "Developer ID Application:"*|"Apple Development:"*|"Apple Distribution:"*|"Mac Developer:"*|"3rd Party Mac Developer Application:"*)
      signing_arguments+=(--options runtime --timestamp)
      ;;
    *) signing_arguments+=(--timestamp=none) ;;
  esac
else
  signing_dir="$HOME/Library/Application Support/Seven/BuildSigning"
  signing_keychain="$signing_dir/SevenBuild.keychain-db"
  signing_password_file="$signing_dir/keychain-password"
  if [[ ! -f "$signing_keychain" || ! -f "$signing_password_file" ]]; then
    print -u2 "本机开发签名尚未配置。请先运行 ./setup-local-signing.sh。"
    exit 1
  fi
  security unlock-keychain -p "$(<"$signing_password_file")" "$signing_keychain"
  signing_identity="$(security find-identity -v -p codesigning "$signing_keychain" | awk '/"Seven Local Development"/ && !found++ { print $2 }')"
  if [[ -z "$signing_identity" ]]; then
    print -u2 "Seven Local Development 签名身份不可用。请重新运行 ./setup-local-signing.sh。"
    exit 1
  fi
  signing_arguments+=(--keychain "$signing_keychain" --timestamp=none)
fi
signing_arguments+=(--sign "$signing_identity")

tmp_dir="$(mktemp -d "$project_dir/.build/seven-app.XXXXXX")"
app="$tmp_dir/$app_name.app"
output_app="$output_dir/$app_name.app"
cleanup_build() {
  if [[ -e "$tmp_dir/previous.app" || -L "$tmp_dir/previous.app" ]] &&
     [[ ! -e "$output_app" && ! -L "$output_app" ]]; then
    if ! mv "$tmp_dir/previous.app" "$output_app"; then
      print -u2 "无法恢复上一个包，已保留在 $tmp_dir/previous.app。"
      return
    fi
  fi
  rm -rf "$tmp_dir"
}
trap cleanup_build EXIT
build_arguments=(-c "$configuration")
if [[ -n "$variant" ]]; then
  build_arguments+=(-Xswiftc -DSEVEN_DEVELOPMENT)
fi

build_slice() {
  local output_binary="$1"
  shift
  swift build "${build_arguments[@]}" "$@"
  binary_dir="$(swift build "${build_arguments[@]}" "$@" --show-bin-path)"
  cp "$binary_dir/Seven" "$output_binary"
  # SwiftPM 为命令行工具附加本机构建工具链路径。分发包只用系统和包内的库。
  local extra_rpaths
  extra_rpaths="$(xcrun otool -l "$output_binary" | awk '
    $2 == "LC_RPATH" {
      getline; getline
      sub(/^[[:space:]]*path /, ""); sub(/ \(offset [[:digit:]]+\)$/, "")
      if ($0 ~ /^\// && $0 != "/usr/lib/swift") print
    }
  ')"
  if [[ -n "$extra_rpaths" ]]; then
    codesign --remove-signature "$output_binary"
    local rpath
    for rpath in "${(@f)extra_rpaths}"; do
      xcrun install_name_tool -delete_rpath "$rpath" "$output_binary"
    done
  fi
}

if [[ "$universal" == true ]]; then
  build_slice "$tmp_dir/Seven-arm64" --arch arm64
  build_slice "$tmp_dir/Seven-x86_64" --arch x86_64
  xcrun lipo -create "$tmp_dir/Seven-arm64" "$tmp_dir/Seven-x86_64" -output "$tmp_dir/Seven"
  xcrun lipo "$tmp_dir/Seven" -verify_arch arm64 x86_64
else
  build_slice "$tmp_dir/Seven"
fi
sparkle_source="$binary_dir/Sparkle.framework"
if [[ ! -f "$sparkle_source/Versions/Current/Sparkle" ]]; then
  print -u2 "SwiftPM 构建目录中缺少 Sparkle.framework。"
  exit 1
fi

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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/BrandIcons" "$app/Contents/Frameworks"
cp "$tmp_dir/Seven" "$app/Contents/MacOS/Seven"
framework="$app/Contents/Frameworks/Sparkle.framework"
cp -RP "$sparkle_source" "$framework"
cp "$project_dir/Info.plist" "$app/Contents/Info.plist"
if [[ "$configuration" != release || -n "$variant" || "$release_signing" == false ]]; then
  # 即使源码含正式公钥，开发包和本机签名包也不应被正式更新替换。
  plutil -remove SUFeedURL "$app/Contents/Info.plist"
  plutil -remove SUPublicEDKey "$app/Contents/Info.plist"
fi
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
sparkle_version="$framework/Versions/Current"
# Sparkle 的 Downloader 可携带网络权限，单独保留其签名权限。
codesign "${signing_arguments[@]}" "$sparkle_version/XPCServices/Installer.xpc"
codesign "${signing_arguments[@]}" --preserve-metadata=entitlements "$sparkle_version/XPCServices/Downloader.xpc"
codesign "${signing_arguments[@]}" "$sparkle_version/Autoupdate"
codesign "${signing_arguments[@]}" "$sparkle_version/Updater.app"
codesign "${signing_arguments[@]}" "$framework"
codesign "${signing_arguments[@]}" --identifier "$bundle_identifier" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

if [[ -e "$output_app" || -L "$output_app" ]]; then
  mv "$output_app" "$tmp_dir/previous.app"
fi
mv "$app" "$output_app"
print "$output_app"
