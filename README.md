<p align="center">
  <img src="Resources/Seven.png" width="96" height="96" alt="Seven" />
</p>

<h1 align="center">Seven</h1>

<p align="center">
  <strong>A native macOS productivity suite unifying AI translation, screen capture, and on-device OCR.</strong>
</p>

<p align="center">
  <a href="https://github.com/crismakes/Seven/releases/latest"><img src="https://img.shields.io/github/v/release/crismakes/Seven?label=Latest%20Release" alt="Latest Release" /></a>
  <a href="https://github.com/crismakes/Seven/releases"><img src="https://img.shields.io/github/downloads/crismakes/Seven/total?label=Downloads" alt="Downloads" /></a>
  <img src="https://img.shields.io/badge/macOS_14%2B-Apple_Silicon_%26_Intel-000000?logo=apple&amp;logoColor=white" alt="macOS 14+ (Apple Silicon &amp; Intel)" />
  <img src="https://img.shields.io/badge/Apple-Notarized-2ea44f" alt="Apple Notarized" />
  <a href="https://github.com/crismakes/Seven/actions/workflows/ci.yml"><img src="https://github.com/crismakes/Seven/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License" /></a>
</p>

<h3 align="center"><a href="https://github.com/crismakes/Seven/releases/latest">Download Latest Release</a></h3>

<p align="center">Signed &amp; Notarized by Apple · Auto-updates built in</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/assets/hero-dark.png" />
    <img src="Docs/assets/hero-light.png" width="840" alt="Seven's translation panel with English input, a Spanish translation, and a Markdown result with a table, list, and copyable code block" />
  </picture>
</p>

## Why Seven

Replace three separate utilities with one lightweight, native menu bar app. Translate and rewrite across apps with AI, capture and annotate screenshots (including long pages) and pin them above your work, or extract text from images entirely on your Mac. Seven is MIT-licensed, uses Developer ID signing, and is notarized by Apple.

## Features

### Translate and rewrite across apps

- **Selection and input translation** — Select text in another app and press `⌥D`, or open the input panel with `⌥A`. Choose a target language directly or let Seven pick between your two preferred languages.
- **Screenshot translation** — Press `⌥S` and select text you can't highlight, such as text in an image or subtitles. Seven recognizes the text on your Mac and passes it to the translation panel.
- **Translate & Replace** — Select text in an editable field and press `⌃⌥T`. Seven verifies the original field and selection before writing the translation back.
- **Translation services and read-aloud** — Use Apple Translation, Youdao, Google, or a downloadable offline English–Chinese dictionary. Bring an API key for streaming services such as OpenAI, Claude, Gemini, and DeepSeek, or use a compatible endpoint. Copy or listen to the input and results.
- **Custom AI prompts** — Summarize, rewrite, or pull out key points in the translation panel, with readable Markdown results and one-click code copying.
- **History and favorites** — Search original text and translations across services, keep favorites in a separate collection, and export either collection as JSON or Markdown.

### Capture, annotate, and pin

- **Regions, windows, and smart selection** — Freeze the screen to select an area or window, combine multiple windows, restore the last region, or copy a HEX color. Enable smart selection to pick controls inside windows.
- **Non-destructive annotation** — Add arrows, shapes, numbered callouts, text, pixelation, or a spotlight. Undo or redo edits, export PNG or JPG at the original resolution, or use the macOS Share menu.

<p align="center">
  <img src="Docs/assets/screenshot-editor.png" width="840" alt="Seven's screenshot editor with a floating toolbar, an arrow, a rectangle, and a numbered callout on a public science article" />
</p>

#### Scrolling capture

Scroll up or down to stitch a long screenshot with a live preview. Annotate, copy, save, share, pin, or extract text from the result.

<p align="center">
  <img src="Docs/assets/scroll-capture.png" width="840" alt="A scrolled selection beside Seven’s live stitched preview and capture controls" />
</p>

#### Floating pins

Keep a screenshot, clipboard image, or text above other windows. Adjust zoom and opacity or annotate the pin in place.

<p align="center">
  <img src="Docs/assets/floating-pin.png" width="840" alt="A floating coral photo pinned above the public article for reference" />
</p>

### Extract text on your Mac

- **On-device OCR and smart layout** — Apple Vision recognizes text on your Mac. Select text directly on the image and use the adjacent pane to edit, reflow paragraphs, translate, or export it as TXT.
- **Silent OCR and image import** — Copy recognition results straight to the clipboard, or send an image to OCR from Finder's Open With menu, drag and drop, or the clipboard. You can also open local images for annotation.

<p align="center">
  <img src="Docs/assets/ocr-window.png" width="840" alt="Seven's OCR window showing a crop from a public science article next to its editable recognized text" />
</p>

The screenshots use a public [NOAA National Ocean Service article about corals](https://oceanservice.noaa.gov/facts/coral.html).

### Make it yours

- Set common languages, translation service order, global shortcuts, and screenshot toolbar actions. The translation panel can follow the pointer, remember its position, or stay pinned.
- Choose from system, light, and dark appearances, with Reduce Motion support and six interface languages (English, Simplified Chinese, Traditional Chinese, Japanese, Korean, and Spanish).

## Download

Seven runs on **macOS 14.0 (Sonoma) or later** on Apple Silicon and Intel.

1. Under **Assets**, download and open the `.dmg`, or download and unzip the `.zip`. [Latest GitHub Release](https://github.com/crismakes/Seven/releases/latest)
2. Drag **Seven** into **Applications**, then open it from there.

Seven checks for updates automatically. In **Settings → About**, you can check manually or turn on **Automatically Download and Install**. Signed, notarized releases are listed in the [update feed](appcast.xml).

Grant **Accessibility** for cross-app selection, Translate & Replace, and optional smart element selection. Grant **Screen Recording** for screenshots, scroll capture, screenshot translation, and screen OCR.

<details>
<summary>Default keyboard shortcuts</summary>

| Action | Default shortcut |
|---|---|
| Selection Translate | `⌥D` |
| Input Translate | `⌥A` |
| Screenshot Translate | `⌥S` |
| Translate & Replace | `⌃⌥T` |
| Region Screenshot | `⌃⌥S` |
| Region OCR | `⌃⌥O` |
| Other capture, image, OCR, and pin actions | Unassigned by default |

</details>

## Privacy

- **Zero telemetry** — Seven collects no usage analytics.
- **Credentials stay on your Mac** — API keys are stored per service instance in a local file with `0700` directory and `0600` file permissions. Keys are excluded from exports and logs.
- **On-device OCR** — Apple Vision recognizes text locally. Online translation sends text to the chosen provider. If local language detection is uncertain, the selected online detector (Youdao by default) can receive up to 500 characters of translation input. You can choose on-device detection in Settings. Speech synthesis defaults to Youdao and requests audio only when you start playback.
- **Technical diagnostics** — The diagnostics pane is hidden in official releases. Development logs record technical events and metrics such as timings and dimensions. They exclude user text, clipboard and OCR content, images, window titles, and credentials.

## Build from source

<details>
<summary>Build, test, and package Seven</summary>

Use **Xcode 26 or later** to build and package Seven. The package declares Swift tools 5.9, and the pinned Markdown dependency requires **Swift 6.2 or later**, which Xcode 26 includes.

```sh
git clone https://github.com/crismakes/Seven.git
cd Seven

swift build
swift test

# Run once if you don't have a Developer ID Application signing identity
./setup-local-signing.sh

./build-app.sh release
open Seven.app
```

SwiftPM fetches the pinned dependencies on the first build. The packaging script uses the certificate name or SHA-1 fingerprint in `SEVEN_SIGN_IDENTITY` when set. Otherwise, it looks for Developer ID Application in the keychain search list, then falls back to the local signing identity. Use `--local-signing` to skip Developer ID auto-detection or `--universal` to package for both Apple Silicon and Intel. For an isolated development build, run `./build-app.sh release --variant dev`.

See [engineering guidelines](AGENTS.md) and the [maintainer release guide (Simplified Chinese)](Docs/Release.md).

</details>

## License & Feedback

Seven is open source under the [MIT License](LICENSE). Bug reports and feature ideas are welcome on [GitHub Issues](https://github.com/crismakes/Seven/issues).
