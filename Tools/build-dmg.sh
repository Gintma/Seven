#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"

fail() {
  print -u2 -- "$1"
  exit 1
}

[[ $# == 2 ]] || fail "用法：./Tools/build-dmg.sh <Seven.app> <输出.dmg>"
app="$1"
output="$2"
app="${app:A}"
output="${output:A}"
background="$project_dir/Resources/DMG/background.png"
volume_icon="$app/Contents/Resources/AppIcon.icns"
[[ -d "$app" && -s "$volume_icon" ]] || fail "应用包不存在或缺少 AppIcon.icns。"
[[ -s "$background" ]] || fail "缺少 DMG 背景图。"
[[ "$output" == *.dmg && ! -d "$output" ]] || fail "输出必须是 .dmg 文件路径。"
mkdir -p "${output:h}"

# 独立于发布暂存目录，避免调用方清理时触及尚未卸载的卷宗。
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/seven-dmg.XXXXXX")"
volume="$stage_dir/mount"
image="$stage_dir/Seven-rw.dmg"

is_mounted() {
  [[ -d "$volume" && "$(stat -f %d "$volume")" != "$(stat -f %d "$stage_dir")" ]]
}

cleanup() {
  if is_mounted && ! hdiutil detach "$volume" -quiet; then
    # 只强制分离本次构建独占的挂载点。若仍失败，保留暂存目录以便恢复。
    if ! hdiutil detach "$volume" -force -quiet; then
      print -u2 "无法卸载临时镜像，请检查 $volume。"
      return 1
    fi
  fi
  rm -rf "$stage_dir"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$volume"
app_kib="$(du -sk "$app" | awk '{print $1}')"
# 按容量新建的 UDIF 镜像默认为可写 UDRW，为 Finder 布局和文件系统元数据留出空间。
hdiutil create -type UDIF -size "$((app_kib + 16384))k" -fs HFS+ -volname Seven "$image"
hdiutil attach "$image" -mountpoint "$volume" -nobrowse -noautoopen

ditto "$app" "$volume/Seven.app"
ln -s /Applications "$volume/Applications"
mkdir "$volume/.background"
cp "$background" "$volume/.background/background.png"
cp "$volume_icon" "$volume/.VolumeIcon.icns"
xcrun SetFile -a C "$volume"

/usr/bin/osascript "$project_dir/Tools/layout-dmg.applescript" "$volume"
for attempt in {1..20}; do
  [[ -s "$volume/.DS_Store" ]] && break
  sleep 0.25
done
[[ -s "$volume/.DS_Store" ]] || fail "Finder 未保存 DMG 窗口布局。"
sync
hdiutil detach "$volume"
hdiutil convert "$image" -format UDZO -o "$stage_dir/Seven.dmg"
mv -f "$stage_dir/Seven.dmg" "$output"
print -r -- "$output"
