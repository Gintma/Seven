# Seven 发版与公证

Seven 通过 GitHub Releases 分发支持 Apple 芯片与 Intel 的通用包，以 Sparkle 为已安装的正式版提供更新。构建和打包使用 Xcode 26 或更新版本。项目声明的 Swift 工具版本为 5.9，锁定的 Markdown 依赖要求 Swift 6.2 或更新版本。

## 1. 配置签名

在钥匙串中安装 **Developer ID Application** 证书及私钥。机器上有多张证书时，可用 `SEVEN_SIGN_IDENTITY` 指定证书全名或 SHA-1 指纹。

首次配置 Sparkle 更新签名时，在仓库根目录运行：

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account seven
```

将输出的公钥填入 [Info.plist](../Info.plist) 的 `SUPublicEDKey`，私钥保留在钥匙串。后续发版沿用与已发布版本公钥匹配的私钥。使用其他现有账号时，通过 `SEVEN_SPARKLE_KEY_ACCOUNT` 指定账号。

## 2. 配置 Apple 公证

用 `notarytool` 将公证凭据保存到钥匙串。以下以 `seven-notary` 为配置名：

```sh
xcrun notarytool store-credentials seven-notary
export SEVEN_NOTARY_PROFILE=seven-notary
```

在交互提示中输入凭据。每次发版前，在运行脚本的终端将 `SEVEN_NOTARY_PROFILE` 设为对应的钥匙串配置名。

## 3. 构建发布产物

在 [Info.plist](../Info.plist) 中设置新的 `CFBundleShortVersionString`，并将 `CFBundleVersion` 递增到高于 [appcast.xml](../appcast.xml) 已有的所有构建号。退出正在运行的 Seven，再执行：

```sh
./Tools/release.sh
```

加上 `--dmg` 可在 ZIP 之外生成签名、公证的 DMG。生成 DMG 需要可运行 Finder 的 macOS 桌面会话。脚本会构建并签名 Universal 应用、提交 Apple 公证、粘贴并验证公证票据，再用 Sparkle 为最终 ZIP 签名。参阅[发布脚本](../Tools/release.sh)。

## 4. 发布 GitHub Release 和更新源

将 `dist/v<version>/` 中的 `Seven-<version>.zip` 和生成的可选 `Seven-<version>.dmg` 上传到 GitHub Release `v<version>`。确认 Release 已公开且 ZIP 可下载，再通过项目的合并流程将脚本更新的 [appcast.xml](../appcast.xml) 发布到 `main`，让 Sparkle 读到可用的下载链接。发布后可在先前安装的正式版中通过「设置 → 关于」检查更新。

## 预览 DMG 安装窗口

在 macOS 桌面会话下，使用已打包的 `Seven.app` 生成预览镜像：

```sh
./Tools/build-dmg.sh Seven.app dist/preview/Seven-preview.dmg
```

预览 DMG 未签名，无需公证凭据。打开镜像即可在 Finder 中检查安装窗口。参阅 [DMG 打包脚本](../Tools/build-dmg.sh)。
