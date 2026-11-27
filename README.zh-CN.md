<p align="center">
  <img src="Resources/Seven.png" width="96" height="96" alt="Seven" />
</p>

<h1 align="center">Seven</h1>

<p align="center">
  <strong>原生 macOS 效率套件，将 AI 翻译、屏幕截图与本机 OCR 融为一体。</strong>
</p>

<p align="center">
  <a href="https://github.com/crismakes/Seven/releases/latest"><img src="https://img.shields.io/github/v/release/crismakes/Seven?label=Latest%20Release" alt="Latest Release" /></a>
  <a href="https://github.com/crismakes/Seven/releases"><img src="https://img.shields.io/github/downloads/crismakes/Seven/total?label=Downloads" alt="Downloads" /></a>
  <img src="https://img.shields.io/badge/macOS_14%2B-Apple_Silicon_%26_Intel-000000?logo=apple&amp;logoColor=white" alt="macOS 14+ (Apple Silicon &amp; Intel)" />
  <img src="https://img.shields.io/badge/Apple-Notarized-2ea44f" alt="Apple Notarized" />
  <a href="https://github.com/crismakes/Seven/actions/workflows/ci.yml"><img src="https://github.com/crismakes/Seven/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License" /></a>
</p>

<h3 align="center"><a href="https://github.com/crismakes/Seven/releases/latest">下载最新版本</a></h3>

<p align="center">Apple 签名公证 · 支持应用内自动更新</p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/assets/hero-dark.png" />
    <img src="Docs/assets/hero-light.png" width="840" alt="Seven 翻译浮窗，展示英文原文、西班牙语译文，以及含表格、列表和可复制代码块的 Markdown 结果" />
  </picture>
</p>

## 为什么选择 Seven

一个轻量原生菜单栏应用，替代平时要分开安装的三类工具。跨应用用 AI 翻译和改写文字，截屏或滚动截长图并标注、钉在桌面上，也能直接在本机提取图片文字。Seven 采用 MIT 协议开源，使用 Developer ID 签名并通过 Apple 公证。

## 核心功能

### 跨应用翻译与改写

- **在手头的应用里翻译** —— 划词、输入或截图即可翻译，也可以用「翻译并替换」将结果写回原输入框。
- **自选翻译服务** —— 支持 Apple 翻译、有道、Google 和可下载的离线英汉词典，也可用自己的 API Key 接入 OpenAI、Claude、Gemini 等服务或自定义兼容接口，流式查看结果。
- **AI 自定义结果的原生 Markdown 排版（已进入 `main`）** —— 在结果卡片中直接阅读表格、引用和列表，单个代码块可一键复制。Markdown 排版下按纯文本朗读，跳过代码块和链接地址。

<details>
<summary>自定义提示词变量与消息发送规则</summary>

自定义模式使用一段提示词。`{{target}}` 插入当前选定的目标语言，`{{firstLanguage}}` 插入设置中的第一语言。

- 包含 `{{text}}` 时，Seven 在指定位置插入原文，将展开后的整段提示词作为一条用户消息发送。
- 省略 `{{text}}` 时，Seven 将提示词作为系统消息发送，再把原文作为一条独立的用户消息发送。

</details>

### 截图、标注与钉图

- **选准画面再标注** —— 冻结屏幕后框选区域或点选窗口，添加箭头、形状、序号或马赛克，再按原始分辨率导出。
- **滚动截取长图** —— 向上或向下滚动时实时拼接，边截边预览，保留完整分辨率。
- **让参考内容留在眼前** —— 将截图、剪贴板图片或纯文字钉在其他窗口上方，可调节缩放和不透明度。

<p align="center">
  <img src="Docs/assets/screenshot-editor.png" width="840" alt="Seven 截图编辑器，展示浮动工具条，以及虚构仪表板上的箭头、序号标注和马赛克" />
</p>

### 在本机提取文字

- **对照原图处理文字** —— 直接在图上选字，对照原图编辑识别结果，再翻译或导出 TXT。静默 OCR 会将识别结果直接复制到剪贴板。
- **从屏幕或图片开始** —— 框选屏幕区域，或通过 Finder、拖放、剪贴板将图片送入 OCR。

<p align="center">
  <img src="Docs/assets/ocr-window.png" width="840" alt="Seven 的 OCR 窗口，左侧为示例指南原图，右侧为可编辑的识别文本" />
</p>

## 下载

支持 **macOS 14.0（Sonoma）及以上版本**，兼容 Apple 芯片和 Intel Mac。

1. 在 **Assets** 中下载并打开 `.dmg`，也可以下载并解压 `.zip`。 [GitHub 最新版本](https://github.com/crismakes/Seven/releases/latest)
2. 将 **Seven** 拖入 **Applications（应用程序）**，再从应用程序文件夹打开。

Seven 会自动检查更新。你也可以在「设置 → 关于」手动检查，或开启「自动下载并安装」。已签名并公证的版本列在[更新源](appcast.xml)中。

跨应用划词、「翻译并替换」和可选的智能选区需要**辅助功能**权限。截图、长截图、截图翻译和屏幕 OCR 需要**屏幕录制**权限。

<details>
<summary>默认快捷键</summary>

| 功能 | 默认快捷键 |
|---|---|
| 划词翻译 | `⌥D` |
| 输入翻译 | `⌥A` |
| 截图翻译 | `⌥S` |
| 翻译并替换 | `⌃⌥T` |
| 区域截图 | `⌃⌥S` |
| 框选 OCR | `⌃⌥O` |
| 其他截图、图片、OCR 与钉图操作 | 默认未设置 |

</details>

## 隐私

- **零遥测** —— Seven 不收集使用统计。
- **凭据留在本机** —— API Key 按服务实例存入本地文件，目录权限为 `0700`，文件权限为 `0600`。导出和日志均不包含密钥。
- **本机 OCR** —— Apple Vision 在本机识别文字。使用在线翻译时，文本会发给所选服务。若本机语种识别不确定，所选联网检测服务（默认有道）最多可收到 500 个字符的翻译输入，也可在设置中选择仅本机识别。语音合成默认使用有道，主动朗读时才请求在线语音。
- **技术诊断** —— 正式版隐藏诊断入口。开发版日志只记录技术事件、耗时、尺寸等指标，不记录原文、译文、剪贴板或 OCR 内容、图像、窗口标题和凭据。

## 从源码构建

<details>
<summary>构建、测试与打包 Seven</summary>

从源码构建和打包使用 **Xcode 26 或更新版本**。项目声明的 Swift 工具版本为 5.9，锁定的 Markdown 依赖实际要求 **Swift 6.2 或更新版本**，Xcode 26 已包含该工具链。

```sh
git clone https://github.com/crismakes/Seven.git
cd Seven

swift build
swift test

# 没有 Developer ID Application 签名身份时执行一次
./setup-local-signing.sh

./build-app.sh release
open Seven.app
```

SwiftPM 首次构建时下载锁定的依赖。打包脚本优先使用 `SEVEN_SIGN_IDENTITY` 指定的证书全名或 SHA-1 指纹，其次查找钥匙串搜索列表中的 Developer ID Application，最后使用本机开发签名。可用 `--local-signing` 跳过 Developer ID 自动查找，或用 `--universal` 同时打包 Apple 芯片与 Intel 版本。需要独立的开发试用包时，运行 `./build-app.sh release --variant dev`。

参阅[工程规范](AGENTS.md)和[维护者发版指南](Docs/Release.md)。

</details>

## 开源协议与反馈

Seven 采用 [MIT 协议](LICENSE)开源。欢迎在 [GitHub Issues](https://github.com/crismakes/Seven/issues) 反馈问题或提出功能建议。
