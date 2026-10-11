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
2. Launch the app; it detects your Chrome session automatically when access is available.
3. Click **Detect Chrome Session** if macOS needs permission to read Chrome Safe Storage.
4. Choose a profile when several Chrome profiles are signed in.

Chrome cookies recheck hourly and usage refreshes every minute. **Open Claude in
Chrome** opens the usage page for sign-in. Manual cookie entry remains available.
Chrome storage is read only; no Accessibility or Automation permission, extension
or remote debugging is required.

## ✨ Features

- 🟢 **Real-time usage tracking** - Monitor session (5-hour) and weekly (7-day) limits
- 🎨 **Color-coded menu bar icon** - Visual spark icon that changes color (green/yellow/red)
- 🔔 **Smart notifications** - Alerts at 25%, 50%, 75%, 90% usage thresholds
- ⌨️ **Keyboard shortcut** - Toggle popup with Cmd+U from anywhere
- ⚡ **Auto-refresh** - Updates every minute, or every 12 seconds above 90% five-hour usage until reset
- 🤖 **Codex tracking** - Claude/Codex selector, per-bucket limits and reset times from your existing Codex sign-in
- 🔒 **Privacy-first** - All data stored locally on your Mac
- 📊 **Pro plan support** - Shows weekly Sonnet usage for Pro subscribers
- 🎯 **Menu bar only** - No Dock icon, stays out of your way

[See full feature list →](app/README.md)

## 🚀 Quick Start

1. **Build** this fork using `cd app && ./build.sh --local`
2. **Open** `app/build/LimitFuel.app` from the repository root
3. **Sign in** to Claude in Chrome or Codex CLI with ChatGPT
4. **Connect Chrome** using Detect Chrome Session (or use the manual fallback)
5. **Done!** Usage appears in menu bar

## 📸 Screenshots

**Menu Bar Display:**
```
⚡ 45%  (Green spark icon when usage < 70%)
```

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

The built app will be in `app/build/LimitFuel.app`. The default build requires
the upstream distribution certificate; use `./build.sh --local` for this fork.

For a local ad-hoc signed build without a distribution certificate, run
`./build.sh --local`; this builds both architectures and does not launch the app.
Run `./Tests/run.sh` from the repository root for offline acceptance tests.
The test runner uses the toolchain and SDK in `/Applications/Xcode.app`.

## Codex setup

Install Codex CLI and sign in with ChatGPT (`codex login`), then select **Codex**
in the popup. The app detects common CLI/app executable locations; **Choose Codex
Executable…** supports other locations. It uses Codex app-server's documented
read-only account and rate-limit methods, so Codex handles its own credentials
and refresh. API-key-only accounts do not expose ChatGPT plan quotas.

Claude and Codex refresh independently. Any five-hour window above 90% switches
its provider to 12-second polling; known resets or usage at/below 90% restore
one-minute polling. Chrome cookies still recheck hourly. Missing quotas display
as unavailable; Codex supports multiple metered buckets and actual window lengths.

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

- 🐛 Report bugs via [Issues](https://github.com/innolope-dev/LimitFuel/issues)
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
- **Issues:** [GitHub Issues](https://github.com/innolope-dev/LimitFuel/issues)
- **Releases:** [GitHub Releases](https://github.com/innolope-dev/LimitFuel/releases)

---

**Made with ❤️ for the Claude community**

LimitFuel keeps the original bundle identifier for settings compatibility. Existing
saved cookies and preferences carry over when upgrading from the original app.
Quit the original app before opening LimitFuel; they share the same settings identity.
