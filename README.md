<p align="center">
  <img src="Resources/Seven.png" width="96" height="96" alt="Seven" />
</p>

<h1 align="center">Seven</h1>

<p align="center">
  <strong>A native macOS productivity suite unifying AI translation, screen capture, and on-device OCR.</strong>
</p>

<p align="center">
  Built for everyday reading, writing, and visual workflows · Swift, AppKit, SwiftUI &amp; C · Updates powered by Sparkle 2
</p>

<p align="center">
  <a href="https://github.com/crismakes/Seven/actions/workflows/ci.yml"><img src="https://github.com/crismakes/Seven/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.9+" />
  <img src="https://img.shields.io/badge/Updates-Sparkle_2-2ea44f" alt="Sparkle 2 updates" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License" /></a>
</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<!-- Visual preview (hero screenshot / demo GIF) reserved here -->

---

## Why Seven

- **AI-Native, Bring Your Own Models** — Stream translations and custom prompts directly from OpenAI, Claude, Gemini, DeepSeek, MiniMax, Zhipu, Kimi, Qwen, Doubao, OpenRouter, or any custom compatible endpoint, alongside built-in Apple Translation and offline dictionary lookup.
- **Unified Reading, Writing & Screen Workflow** — Translate across apps, rewrite in place with Translate & Replace, capture and annotate screenshots (including pure-C scroll stitching and floating pins), and extract text locally from one quiet menu bar app.
- **Native macOS** — Built on AppKit, SwiftUI, Apple Vision, Apple Translation, and a pure C scroll-stitching core (`ScrollRegistrationCore`). Sparkle 2 handles app updates.
- **Local-First & Privacy-Respecting** — OCR runs entirely on-device via Apple Vision, API keys stay on your Mac (`0700`/`0600` local file), and there is zero analytics or telemetry.
- **Crafted for macOS** — Native overlay scrollbars, 30 built-in light/dark themes plus system appearance, reduced-motion support, and 6 interface languages (English, Simplified Chinese, Traditional Chinese, Japanese, Korean, and Spanish).

---

## Features

### Translation & In-Place Replacement

- **Multiple Entry Points** — Input translation, cross-app selection translation (`⌥D`), screenshot translation (`⌥S`), and in-place **Translate & Replace** (`⌃⌥T`) that safely verifies target focus and UTF-16 selection before writing back.
- **Built-in & Bring-Your-Own-Key Providers** — Apple Translation, offline English-Chinese dictionary (ECDICT), Youdao, and Google built in; streaming BYOK support for OpenAI, Claude, Gemini, DeepSeek, MiniMax, Zhipu, Kimi, Qwen, Doubao, OpenRouter, and custom compatible endpoints.
- **Smart Language Routing & Custom Prompts** — Automatic first/second language routing with fixed-target override, streaming responses that respect your reading scroll position, custom prompts (`{{text}}`, `{{source}}`, `{{target}}`, `{{firstLanguage}}`), offline TTS, and searchable multi-service translation history, separate favorites, and JSON/Markdown export.

### Screenshots, Scroll Capture & Floating Pins

- **Frozen Region & Smart Selection** — Whole-window hover/click, manual drag, `⌘`-click multi-window compositing, `⇧` square lock, `F` fullscreen, `R` restore previous region, `C` copy HEX color, and optional Accessibility-backed smart element selection.
- **Non-Destructive Annotation** — Mosaic, arrows/shapes, spotlight focus, numbered callouts, and styled text with full undo/redo and original-pixel PNG/JPG export or macOS Share Sheet handoff.
- **Manual Scroll Capture** — Pure C image registration stitches upward and downward scrolling in real time with a live crisp preview and full-resolution output.
- **Floating Pins** — Pin any screenshot, clipboard image, or rendered plain text on top of your workspace; adjust zoom and opacity with the scroll wheel and edit annotations in place without degrading export pixels.

### Local OCR & Image Input

- **On-Device Recognition** — Interactive OCR opens an editable side-by-side window with direct text selection on the source image, zoom/pan, smart paragraph formatting, one-click translate, and TXT export; Silent OCR copies recognized text straight to your clipboard.
- **Flexible Image Inputs** — Open local images (`PNG`, `JPEG`, `HEIC`, `TIFF`, `BMP`, `GIF`, `WebP`) into the screenshot editor, or send images from Finder ("Open With → Seven"), drag-and-drop, or clipboard directly into OCR.

---

## Installation

### Requirements

- **macOS 14.0 (Sonoma)** or later
- **Xcode 15+ / Swift 5.9+** to build from source. The app packaging script requires Xcode 26+ for Icon Composer assets.

### Download

Pre-built releases will be published on the [GitHub Releases](https://github.com/crismakes/Seven/releases) page.

### Build from Source

```sh
git clone https://github.com/crismakes/Seven.git
cd Seven

# One-time setup if you are building without a Developer ID Application certificate
./setup-local-signing.sh

# Build and sign Seven.app for the current architecture
./build-app.sh release
open Seven.app
```

Build with Xcode 26 or later. SwiftPM downloads the locked Sparkle dependency on first resolve. Packaging uses `SEVEN_SIGN_IDENTITY` if set to a certificate name or SHA-1 fingerprint, then a Developer ID Application identity from the keychain search list, then the local signing identity. Use `--local-signing` to skip Developer ID auto-detection and `--universal` to build for Apple Silicon and Intel.

### Updates and Release Packaging

Seven checks for updates in the background. In **Settings → About**, check manually, open the current version’s release page, or opt into automatic downloading and installation. Sparkle can install a downloaded update when Seven quits. The update shortcut appears in the menu bar menu and Settings sidebar when a new version is available. Only a Developer ID-signed release build with a configured feed and public key enables Sparkle.

1. Install a Developer ID Application certificate and its private key. Run `swift package resolve`, then `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account seven`. Copy the public key into `SUPublicEDKey` in `Info.plist`. Keep the private key in the Keychain.
2. Run `xcrun notarytool store-credentials <profile-name>`, then set `SEVEN_NOTARY_PROFILE` to that profile name.
3. Set the release version and increase `CFBundleVersion` in `Info.plist`. Quit Seven and run `./Tools/release.sh` (add `--dmg` for a signed, notarized disk image).
4. Upload the assets from `dist/v<version>/` to GitHub Release `v<version>`, then publish the updated `appcast.xml` on `main`.

To preview the installer layout, run `./Tools/build-dmg.sh Seven.app dist/preview/Seven-preview.dmg` from a macOS desktop session. The preview DMG is unsigned and does not require notarization credentials.

On the first launch under `com.crissun.seven`, Seven copies existing settings if the new preference domain is empty. macOS may ask you to grant Accessibility and Screen Recording access for the new app identity.

---

## Default Shortcuts & Permissions

| Action | Default Shortcut |
|---|---|
| Selection Translate | `⌥D` |
| Input Translate | `⌥A` |
| Screenshot Translate | `⌥S` |
| Translate & Replace | `⌃⌥T` |
| Region Screenshot | `⌃⌥S` |
| Region OCR | `⌃⌥O` |
| Other capture, image, OCR, and pin actions | Unassigned by default |

- **Accessibility** — Required only for cross-app selection reading, Translate & Replace write-back, and optional smart element selection.
- **Screen Recording** — Required for screenshot capture, scroll capture, screenshot translation, and screen OCR.

---

## Privacy & Local Data

- **Zero Telemetry** — Seven does not collect usage analytics or upload anything in the background.
- **Local Credentials** — BYOK API keys are stored per service instance in `~/Library/Application Support/Seven/credentials.json` (`0700` directory, `0600` file permissions) and are never included in exports or logs.
- **On-Device OCR** — Screen and image OCR runs locally via Apple Vision; text is sent to a translation provider only when you explicitly trigger translation.
- **Diagnostic Logs** — Hidden in release builds; when enabled in development builds, logs record only technical events and metrics (timings, counts, dimensions, error types) and strictly exclude user text, clipboard/OCR content, images, window titles, and credentials.

---

## Development

```sh
swift build                                # Must compile with zero warnings
swift test                                 # Offline unit & regression suite
./build-app.sh release --variant dev       # Isolated test app (Seven-dev.app)
```

Engineering guidelines, architecture maps, and module contracts are documented in [AGENTS.md](AGENTS.md).

---

## Maintenance & License

Seven is open source under the [MIT License](LICENSE) and is independently maintained. Bug reports and feature ideas are welcome via [GitHub Issues](https://github.com/crismakes/Seven/issues); external pull requests are currently not accepted.
