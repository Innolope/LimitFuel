# LimitFuel

> Track Claude and Codex usage right from your Mac menu bar.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-12.0+-blue.svg)](https://www.apple.com/macos/)

A lightweight, open-source macOS menu bar application that displays Claude and Codex usage limits with updates and notifications. This fork adds automatic Chrome session detection and adaptive polling.

## 📥 Download

Build this fork with `cd app && ./build.sh --local`. The app is created at
`app/build/LimitFuel.app`. Fork changes have not been released as a notarized installer.
Original project: [Artzainnn/ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar).

## 📦 Set Up (1mn)

1. Sign in to [claude.ai/settings/usage](https://claude.ai/settings/usage) in Google Chrome.
2. Launch the app; it picks up your Chrome session automatically.
3. If it isn't connected yet, click **Detect Chrome Session** and allow access to
   "Chrome Safe Storage" when macOS asks.
4. If several Chrome profiles are signed in, choose one.
5. For Codex, the app uses your existing Codex CLI sign-in (`codex login` with
   ChatGPT if needed); its limits appear below Claude's. See [Codex setup](#codex-setup).

Usage refreshes every minute and Chrome cookies recheck hourly. **Open Claude in
Chrome** opens the sign-in page. Chrome storage is only read; no Accessibility or
Automation permission, extension or remote debugging is required. A manual cookie
option remains for other browsers.

## ✨ Features

- 🟢 **Real-time usage tracking** - Monitor session (5-hour) and weekly (7-day) limits
- 🎨 **Compact menu bar display** - Claude and OpenAI marks with one percentage and reset countdown per connected provider; the app mark appears when neither is connected
- 🔄 **Used or remaining** - Remaining is the menu bar default; switch to Used and choose each provider's limit independently in Settings
- 🔔 **Smart notifications** - Alerts at 25%, 50%, 75%, 90% usage thresholds
- ⌨️ **Keyboard shortcut** - Toggle popup with Cmd+U from anywhere
- ⚡ **Auto-refresh** - Updates every minute, or every 12 seconds above 90% five-hour usage until reset
- 🤖 **Codex tracking** - Claude and Codex limits side by side, with per-bucket limits and reset times from your existing Codex sign-in
- 🔒 **Privacy-first** - Local credentials and read-only provider access, with a Settings opt-out for diagnostics
- 📊 **Pro plan support** - Shows weekly Sonnet usage for Pro subscribers
- 🩺 **Crash and error reporting** - Sentry reporting is on by default, with an off switch in Settings; see [diagnostics and privacy](docs/diagnostics.md)
- 🎯 **Menu bar only** - No Dock icon, stays out of your way

[See full feature list →](app/README.md)

## 🚀 Quick Start

1. **Build** this fork using `cd app && ./build.sh --local`
2. **Open** `app/build/LimitFuel.app` from the repository root
3. **Sign in** to Claude in Chrome or Codex CLI with ChatGPT
4. **Connect Chrome**: the session is picked up automatically, or click Detect Chrome Session
5. **Done!** Usage appears in menu bar

## 📸 Screenshots

**Menu Bar Display:**
```
Claude mark 82% [4h]   OpenAI mark 85% [6d]
```

The percentages show remaining capacity by default. In Settings → Menu bar
usage, turn off **Show remaining percentage** to show used capacity. The badge
shows time until that selected limit resets, with one unit: days, hours, or minutes.
Unknown reset times omit the badge. Tooltips identify the percentage meaning.

Temporary refresh failures keep the last successful value visible. After ten
minutes without a successful update, that provider's numbers gradually blur,
reaching the maximum at thirty minutes. Tooltips retain exact values and update
age; Increase Contrast or Reduce Transparency keeps the numbers sharp.

**Popup Interface:**
- Session (5-hour) usage with progress bar
- Weekly (7-day) usage with progress bar
- Weekly Sonnet usage (Pro plan only)
- Settings for notifications and shortcuts

## 📁 Repository Structure

```
app/        - macOS menu bar application (Swift/SwiftUI)
website/    - Landing page (HTML/CSS)
```

## Build from Source

**Requirements:**
- macOS 12.0 (Monterey) or later
- Xcode Command Line Tools

**Build the app:**
```bash
cd app
chmod +x build.sh
./build.sh --local
```

The built app will be in `app/build/LimitFuel.app`. The default build uses Innolope's
Developer ID identity; use `./build.sh --local` without a distribution certificate.
See [distribution instructions](docs/DISTRIBUTION.md) for Keychain-based notarization
and the separate Mac App Store requirements. No credentials belong in Git.

For a local ad-hoc signed build without a distribution certificate, run
`./build.sh --local`; this builds both architectures and does not launch the app.
The build downloads a checksum-pinned official Sentry SDK and its MIT license.
For offline acceptance tests, prepare it once with
`python3 app/scripts/fetch_sentry.py`, then run `./Tests/run.sh` from the repository root.
The test runner uses the toolchain and SDK in `/Applications/Xcode.app`.

## Codex setup

Install Codex CLI and sign in with ChatGPT (`codex login`); Codex limits then
appear in the popup under Claude. The app detects common CLI/app executable locations; **Choose Codex
Executable…** in Settings supports other locations. It uses Codex app-server's documented
read-only account and rate-limit methods, so Codex handles its own credentials
and refresh. API-key-only accounts do not expose ChatGPT plan quotas.

Claude and Codex refresh independently. Any five-hour window above 90% switches
its provider to 12-second polling; known resets or usage at/below 90% restore
one-minute polling. Chrome cookies still recheck hourly. Missing usage windows
are hidden; Codex supports multiple metered buckets and actual window lengths.

## 🔧 Development

### Project Structure

- `app/LimitFuel.swift` - Main application code
- `app/build.sh` - Build script
- `app/create_dmg.sh` - DMG installer creation
- `website/index.html` - Landing page

### Key Technologies

- **SwiftUI** - Modern macOS UI framework
- **AppKit** - Menu bar integration
- **Carbon** - Global keyboard shortcuts
- **NSUserNotification** - System notifications (no permissions needed)

## 🤝 Contributing

Contributions are welcome! Here's how you can help:

- 🐛 Report bugs via [Issues](https://github.com/Innolope/LimitFuel/issues)
- 💡 Suggest features or improvements
- 🔧 Submit pull requests
- 📖 Improve documentation
- 🌍 Translate the website

## 📄 License

MIT License - see [LICENSE](LICENSE) for details

## ⚠️ Disclaimer

This app uses Claude.ai's internal API endpoints which may change without notice. It is not affiliated with or endorsed by Anthropic or OpenAI. Use at your own risk.

## 🙏 Support

If you find this useful, consider:
- ⭐ Starring this repository
- 📢 Sharing with others who use Claude

## 🔗 Links

- **Upstream website:** [claudeusagebar.com](https://claudeusagebar.com)
- **Issues:** [GitHub Issues](https://github.com/Innolope/LimitFuel/issues)
- **Releases:** [GitHub Releases](https://github.com/Innolope/LimitFuel/releases)

---

**Made with ❤️ for the Claude community**

LimitFuel keeps the original bundle identifier for settings compatibility. Existing
saved cookies and preferences carry over when upgrading from the original app.
Quit the original app before opening LimitFuel; they share the same settings identity.
