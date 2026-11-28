# Security Policy

## Supported Versions

Security fixes are released for the latest public version of Seven listed on [GitHub Releases](https://github.com/crismakes/Seven/releases/latest) and the [Sparkle update feed](appcast.xml).

## Reporting a Vulnerability

Please do not open a public GitHub issue for security or privacy vulnerabilities.

Use GitHub's [private vulnerability reporting](https://github.com/crismakes/Seven/security/advisories/new) to share:

- Affected version and macOS release
- Steps to reproduce or proof of concept
- Potential impact (for example, credential exposure, unauthorized file/network access, or update verification bypass)

You can expect an initial response within a few days.

## Security & Privacy Model

- **Zero telemetry**: Seven collects no analytics or usage tracking.
- **Local credentials**: API keys are stored only on your Mac in a local file (`0700` directory, `0600` file permissions) and are excluded from exports and logs.
- **Verified updates**: Official releases are signed with an Apple Developer ID certificate, notarized by Apple, and verified by Sparkle using EdDSA signatures.
- **On-device OCR**: Text recognition runs locally through Apple Vision; online translation and speech requests are sent only to the services you enable.
