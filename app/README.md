# LimitFuel

> Track Claude and Codex limits from your Mac menu bar.

A lightweight macOS menu bar app that displays your Claude.ai session and weekly usage limits with real-time updates and notifications.

## ✨ Features

- 🟢 **Real-time Usage Tracking**: Monitor session (5-hour) and weekly (7-day) usage
- 🎨 **Monochrome Provider Icons**: Claude and OpenAI marks with separate usage percentages; unavailable providers are hidden
- 🔔 **Smart Notifications**: Alerts at 25%, 50%, 75%, and 90% usage thresholds
- ⚡ **Auto-Refresh**: Every minute, or every 12 seconds above 90% five-hour usage until reset
- 🤖 **Codex**: Separate provider tab with metered buckets, window durations and reset times
- ⌨️ **Keyboard Shortcut**: Toggle popup with Cmd+U from anywhere
- 🔒 **Privacy First**: All data stored locally on your Mac
- 📊 **Pro Plan Support**: Shows weekly Sonnet usage for Pro subscribers
- 🎯 **Menu Bar Only**: No Dock icon, stays out of your way

## 🖼️ Screenshots

**Menu Bar Display:**
- Shows each connected provider's current usage percentage beside its monochrome mark
- Example: `🟢 45%` (green < 70%, yellow 70-90%, red > 90%)

**Popup Interface:**
- Session (5-hour) usage with progress bar and reset time
- Weekly (7-day) usage with progress bar and reset date
- Weekly Sonnet usage (Pro plan only)
- Settings for notifications and keyboard shortcuts

## 📋 Requirements

- macOS 12.0 (Monterey) or later
- Apple Silicon (M1/M2/M3) or Intel Mac
- Active Claude.ai account (Free or Pro)

## 🚀 Installation

Build this fork locally; a LimitFuel notarized installer has not been published.

```bash
cd app
./build.sh --local
```

Open `app/build/LimitFuel.app` from the repository root. This local build is
ad-hoc signed and does not launch automatically.

## 🔧 First-Time Setup

When you first launch LimitFuel, you'll see a welcome message. Follow these steps:

### Automatic Chrome connection

Sign in to Claude in Google Chrome, then use **Detect Chrome Session**. The app
checks automatically at launch and hourly while Chrome sync is enabled. If several
profiles are signed in, choose one; subsequent checks stay on that profile.
**Open Claude in Chrome** opens the usage page. On explicit detection, macOS may
ask for Chrome Safe Storage Keychain access. Background checks never prompt.
Missing, expired, locked or unsupported storage produces a visible message and
preserves the saved cookie. Click Detect after signing in or unlocking.

Manual Save or Clear stops hourly imports until you explicitly detect Chrome again.
Saving or clearing cancels stale usage requests. Existing cookies/settings remain.
Standard Google Chrome Default/Profile N directories are supported; custom data
directories, other channels and browsers need manual entry.

### Manual fallback: getting your session cookie

1. Go to **Settings > Usage** on claude.ai
2. Press **F12** (or Cmd+Option+I on Mac)
3. Go to **Network** tab in DevTools
4. Refresh the page, click the "usage" request
5. Find **'Cookie'** in Request Headers
6. Copy the **full cookie value** (starts with `anthropic-device-id=...`)

### Adding Cookie to App

1. Click **"Use a Manual Cookie"** in the app
2. Paste your cookie (Cmd+V works!)
3. Click **"Save Cookie & Fetch"**
4. Your usage will appear immediately! 🎉

## ⚙️ Settings

Access settings by clicking the gear icon in the popup:

### Notifications
- Enable/disable usage alerts
- Get notifications at 25%, 50%, 75%, 90% thresholds
- Click "Test Notification" to verify it works

### Keyboard Shortcut (Cmd+U)
- Toggle popup from anywhere on your Mac
- Uses Carbon global hotkeys without an Accessibility request
- Disable it in Settings if it conflicts with another app

### Launch at Login
- Start LimitFuel automatically when you log in

## 🔒 Privacy & Security

- ✅ **All data stays on your Mac** - stored in UserDefaults only
- ✅ **No analytics or tracking** - zero external services
- ✅ **Session cookies stored locally** - never sent anywhere except claude.ai
- ✅ **No hardcoded credentials** - org ID extracted dynamically from your cookie
- ✅ **Open source** - review the code yourself

## 🎯 How It Works

1. Uses your session cookie to authenticate with claude.ai API
2. Fetches usage data from the same endpoints the website uses
3. Extracts org ID dynamically from your cookie
4. Displays real-time usage in your menu bar
5. Sends notifications when you hit usage thresholds

## 🔨 Building & Distribution

### Build the App
```bash
./build.sh --local
```

### Create DMG Installer
```bash
./create_dmg.sh
```

### Clean Build
```bash
rm -rf build
./build.sh --local
```

## 🐛 Troubleshooting

### "No data yet" showing
- Sign in to Claude in Chrome, then click Detect Chrome Session
- Choose the correct profile if several are signed in
- Use the manual fallback if Chrome storage cannot be read

### Cookie expired
- Session cookies expire periodically
- Chrome cookies recheck hourly; click Detect Chrome Session for an immediate check
- Sign in again using Open Claude in Chrome if needed
- Manual users can paste a fresh full cookie header

### Notifications not working
- Click "Test Notification" in Settings
- Notifications work without permission prompts
- Check macOS Focus mode isn't blocking them

### Cmd+U shortcut not working
- Enable Keyboard Shortcut in Settings
- Check whether another app has registered Cmd+U
- Disable/re-enable the shortcut or restart the app to register again

### Usage not updating
- App auto-refreshes every minute
- Click the refresh button to update manually
- If cookie expired, get a new one

## 📦 Distribution

Local builds produce `build/LimitFuel.app`. Distribution signing and notarization
require a configured Developer ID and are separate from local development.

## 🤝 Contributing

This is a personal project, but feel free to:
- Report bugs via Issues
- Suggest features
- Submit pull requests
- Fork and customize for your needs

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details

## ⚠️ Disclaimer

This app uses claude.ai's internal API endpoints which may change without notice. It is not affiliated with or endorsed by Anthropic. Use at your own risk.

## 🙏 Acknowledgments

Built with:
- SwiftUI for the interface
- AppKit for menu bar integration
- Carbon for global keyboard shortcuts
- NSUserNotification for alerts

---

**Made with ❤️ for the Claude community**

## Local development checks

Run `./Tests/run.sh` from the repository root. Tests use synthetic cookies and
injected responses to cover encryption, limits, SQLite WAL/locks, profile isolation,
refresh coalescing and stale responses after session changes.

Use `./build.sh --local` in `app/` for an explicitly ad-hoc signed universal build.
It does not launch automatically and is not a notarized distribution artifact.
The default build still requires the configured Developer ID certificate and
fails on signing errors. Never use local mode for a public release.

Session cookies retain the existing local UserDefaults storage for compatibility.
Chrome Safe Storage keys are requested through macOS Keychain and held only during
an import; cookie values, keys and raw API responses are never logged.

## Codex connection

Install Codex CLI and sign in with ChatGPT using `codex login`. Select Codex in
the popup; choose its executable if it is outside common installation locations.
Only initialization, account/read and account/rateLimits/read RPCs are issued.
No threads, inference, credit purchases/resets or email actions are started.
Codex owns its authentication and renewal; the app never stores its tokens.
Missing sign-in, unavailable executable or invalid/failed checks show an error
and clear stale Codex data. CLI subprocesses have a 20-second timeout.

Both providers poll independently every minute, increasing to 12 seconds only
while a five-hour window is above 90%. At a known reset, or when usage drops to
90% or below, polling returns to one minute. Status checks remain every minute
and Chrome cookie import remains hourly. Smart alerts share the usage notification
setting, with Codex deduplication scoped to its account, bucket and quota window.

Existing manual-cookie installations start in manual mode to preserve their
chosen identity. Click Detect Chrome Session to opt into automatic hourly sync.
