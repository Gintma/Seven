<p align="center">
  <img src="Resources/Seven.png" width="96" height="96" alt="Seven" />
</p>

<h1 align="center">Seven</h1>

<p align="center">
  <strong>原生 macOS 效率套件，将 AI 翻译、屏幕截图与本机 OCR 融为一体。</strong>
</p>

<p align="center">
  为日常阅读、写作与屏幕信息处理打造 · 基于 Swift、AppKit、SwiftUI 与 C 构建 · 零第三方依赖
</p>

<p align="center">
  <a href="https://github.com/Gintma/Seven/actions/workflows/ci.yml"><img src="https://github.com/Gintma/Seven/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.9+" />
  <img src="https://img.shields.io/badge/Dependencies-0-2ea44f" alt="零第三方依赖" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License" /></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

<!-- 视觉预览图 / 演示动图预留位 -->

---

## 为什么选择 Seven

- **AI 原生，自带主流模型** — 统一流式接入 OpenAI、Claude、Gemini、DeepSeek、MiniMax、智谱、Kimi、千问、豆包、OpenRouter 及自定义兼容接口，支持自定义 Prompt 与「翻译并替换」，同时内置 Apple 翻译与离线英汉词典。
- **一站式屏幕信息效率工作流** — 将跨应用 AI 翻译、冻结截图标注、长截图、悬浮钉图与本机离线 OCR 整合在一个轻量的菜单栏应用里，打通阅读、写作与信息捕捉。
- **纯原生、零第三方依赖** — 直接基于 AppKit、SwiftUI、Apple Vision、Apple Translation 与纯 C 滚动配准内核（`ScrollRegistrationCore`）构建，不引入任何第三方包。
- **隐私本地优先** — OCR 全程通过 Apple Vision 在本机完成，自备 API Key 按实例存在本地受限权限文件（`0700`/`0600`），无任何统计上报或后台遥测。
- **贴合 macOS 原生体验** — 原生悬浮滚动条、30 套内置浅/深主题与系统默认外观、减弱动态效果适配，并支持 6 种界面语言（简中、繁中、英、日、韩、西）。

---

## 核心功能

### 翻译与原地替换

- **多入口触发** — 支持输入翻译、跨应用划词翻译（`⌥D`）、截图翻译（`⌥S`），以及「翻译并替换」（`⌃⌥T`），写回前会核对目标进程、编辑控件与 UTF-16 选区。
- **内置 + 自带密钥服务** — 内置 Apple 翻译、离线简明英汉词典（ECDICT）、有道与 Google；自带密钥服务统一流式输出，支持 OpenAI、Claude、Gemini、DeepSeek、MiniMax、智谱、Kimi、千问、豆包、OpenRouter 与自定义兼容接口。
- **智能语言路由与自定义 Prompt** — 第一/第二语言自动识别与固定目标语言切换，流式输出尊重你的阅读滚动位置；支持自定义 Prompt 变量（`{{text}}`、`{{source}}`、`{{target}}`、`{{firstLanguage}}`）、离线朗读与历史记录检索/收藏/导出（JSON、Markdown）。

### 截图、长截图与钉图

- **冻结选区与智能选区** — 支持悬停点选整窗、手动拖选、按住 `⌘` 多窗口合成、按住 `⇧` 正方形、`F` 全屏、`R` 恢复上次选区、`C` 取色复制 HEX；开启智能选区后还可识别窗口内的面板、按钮、输入框和图片。
- **无损标注与输出** — 提供马赛克、形状箭头、聚焦遮罩、序号/圆点标注与多样式文字，支持完整撤销/重做，导出保留原图像素（PNG/JPG），并支持系统共享菜单。
- **手动滚动长截图** — 纯 C 图像配准内核支持向上与向下滚动实时拼接，附带清晰悬浮预览并保留原始导出分辨率。
- **悬浮钉图** — 支持将截图、剪贴板图片或纯文字排版钉在屏幕上，滚轮调节缩放与不透明度，支持原位二次编辑标注且不影响导出像素。

### 本机 OCR 与图片输入

- **离线文字识别** — 独立 OCR 提供原图对照与可编辑分栏窗口，支持原图直接拖选复制、缩放平移、智能排版、一键翻译与导出 TXT；静默 OCR 识别后直接将文字写入剪贴板。
- **灵活图片入口** — 支持 `PNG`、`JPEG`、`HEIC`、`TIFF`、`BMP`、`GIF`、`WebP`；「打开本地图片…」进入截图编辑，Finder「打开方式 → Seven」、拖入窗口与剪贴板 OCR 直接进入本机识别。

---

## 安装与构建

### 系统要求

- **macOS 14.0（Sonoma）** 及以上版本
- **Xcode 15+ / Swift 5.9+** 用于从源码构建。应用打包脚本需要 Xcode 26 或更新版本来编译分层图标。

### 下载使用

预编译版本将发布在 [GitHub Releases](https://github.com/Gintma/Seven/releases)。

### 从源码构建

```sh
git clone https://github.com/Gintma/Seven.git
cd Seven

# 首次运行：在本机创建 Seven 专用开发签名身份
./setup-local-signing.sh

# 构建并签名 Seven.app
./build-app.sh release
open Seven.app
```

> `./setup-local-signing.sh` 仅将本机开发签名身份保存在 `~/Library/Application Support/Seven/BuildSigning`，用于在本地反复构建后保持辅助功能与录屏权限不丢失。

---

## 默认快捷键与权限说明

| 功能 | 默认快捷键 |
|---|---|
| 划词翻译 | `⌥D` |
| 截图翻译 | `⌥S` |
| 翻译并替换 | `⌃⌥T` |
| 输入翻译 / 截图 / 长截图 / OCR / 钉图 | 可在设置中自由录制 |

- **辅助功能权限**：仅用于跨应用划词读取、「翻译并替换」安全写回，以及可选的智能选区控件识别。
- **屏幕录制权限**：仅用于截图框选、滚动长截图、截图翻译与屏幕 OCR。

---

## 隐私与本地数据

- **零遥测**：不收集使用统计，不在后台上传任何用户内容。
- **本地凭据隔离**：自带密钥服务的 API Key 按实例保存在 `~/Library/Application Support/Seven/credentials.json`（目录权限 `0700`、文件权限 `0600`），绝不进入历史或诊断导出。
- **本机离线 OCR**：截图与图片文字识别均由 Apple Vision 在本机完成，仅在你主动触发翻译时才向所选翻译服务发送文本。
- **诊断日志边界**：正式 Release 隐藏诊断入口；开发包中诊断日志仅记录技术事件与脱敏指标（耗时、数量、像素尺寸、错误类型等），严禁记录原文、译文、剪贴板/OCR 文本、截图图像、窗口标题与凭据。

---

## 开发

```sh
swift build                                # 必须零警告
swift test                                 # 离线单元测试与回归套件
./build-app.sh release --variant dev       # 独立凭据目录的开发试用包（Seven-dev.app）
```

工程规范、代码结构与各模块契约见 [AGENTS.md](AGENTS.md)。

---

## 维护说明与开源协议

Seven 采用 [MIT 协议](LICENSE) 开源，由作者独立维护。欢迎通过 [GitHub Issues](https://github.com/Gintma/Seven/issues) 反馈缺陷或提出功能建议，暂不接受外部 Pull Request。
