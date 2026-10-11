# LimitFuel

> Track Claude and Codex limits from your Mac menu bar.

A lightweight macOS menu bar app that displays your Claude.ai session and weekly usage limits with real-time updates and notifications.

## ✨ Features

- 🟢 **Real-time Usage Tracking**: Monitor session (5-hour) and weekly (7-day) usage
- 🎨 **Monochrome Provider Icons**: Claude and OpenAI marks with one percentage and reset countdown each; the app mark appears when neither is connected
- 🔄 **Remaining or Used**: Remaining is the menu bar default, with a Settings toggle and an independent limit choice per provider
- 🔔 **Smart Notifications**: Alerts at 25%, 50%, 75%, and 90% usage thresholds
- ⚡ **Auto-Refresh**: Every minute, or every 12 seconds above 90% five-hour usage until reset
- 🤖 **Codex**: Metered buckets, available windows and reset times alongside Claude
- ⌨️ **Keyboard Shortcut**: Toggle popup with Cmd+U from anywhere
- 🔒 **Privacy First**: Local credentials and read-only provider access, with a Settings opt-out for diagnostics
- 📊 **Pro Plan Support**: Shows weekly Sonnet usage for Pro subscribers
- 🎯 **Menu Bar Only**: No Dock icon, stays out of your way

## 🖼️ Screenshots

**Menu Bar Display:**
- Shows each connected provider's remaining capacity beside its monochrome mark
- Example: `Claude mark 82% [4h]   OpenAI mark 85% [6d]`
- Settings → Menu bar usage → **Show remaining percentage** switches between
  remaining (on, the default) and used (off). Each provider keeps its selected limit.
- The badge shows one unit of time until reset: days, hours, or minutes. Unknown
  reset times omit the badge while preserving the percentage.
- Temporary refresh failures retain last-known values. Text gradually blurs from
  ten to thirty minutes without a successful provider update; exact values and
  update age remain in tooltips. Increase Contrast or Reduce Transparency disables blur.

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

### Claude: automatic Chrome connection

1. Sign in to claude.ai in Google Chrome. **Open Claude in Chrome** in the popup
   opens the sign-in page.
2. Launch LimitFuel. It picks up the Chrome session automatically.
3. If it isn't connected yet, click **Detect Chrome Session** and allow access to
   "Chrome Safe Storage" when macOS asks. Background checks never prompt.
4. If several Chrome profiles are signed in, choose one; subsequent checks stay on
   that profile.

No browser extension, Accessibility or Automation permission is needed; Chrome
storage is only read. Missing, expired, locked or unsupported storage produces a
visible message and preserves the saved cookie. Click Detect after signing in or
unlocking. Standard Google Chrome Default/Profile N directories are supported.

A manual cookie option remains for other browsers, Chrome channels and custom data
directories. Saving or clearing a manual cookie stops hourly imports until you
click Detect Chrome Session again.

### Codex

LimitFuel uses your existing Codex CLI sign-in; run `codex login` with ChatGPT if
needed; Codex limits appear in the popup under Claude. See [Codex connection](#codex-connection).

Both providers refresh every minute, or every 12 seconds above 90% five-hour usage
until reset. Chrome cookies are rechecked hourly.

## ⚙️ Settings

Access settings by clicking the gear icon in the popup:

### Notifications
- Enable/disable usage alerts
- Get notifications at 25%, 50%, 75%, 90% thresholds
- Click "Send Test Notification" to verify it works

### Keyboard Shortcut (Cmd+U)
- Toggle popup from anywhere on your Mac
- Uses Carbon global hotkeys without an Accessibility request
- Disable it in Settings if it conflicts with another app

### Launch at Login
- Start LimitFuel automatically when you log in

## 🔒 Privacy & Security

- ✅ **Session cookies stored locally** - never sent anywhere except claude.ai
- ✅ **Read-only provider access** - Codex handles its own sign-in and usage requests
- ✅ **Controllable diagnostics** - crash and error reports are on by default and
  can be disabled immediately in Settings. Reports exclude credentials, account
  details, application logs and request data; see [diagnostics and privacy](../docs/diagnostics.md)
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
- If macOS asked for Chrome Safe Storage access and you denied it, click Detect Chrome Session again and allow it

### Cookie expired
- Session cookies expire periodically
- Chrome cookies recheck hourly; click Detect Chrome Session for an immediate check
- Sign in again using Open Claude in Chrome if needed

### Notifications not working
- Click "Send Test Notification" in Settings
- Notifications work without permission prompts
- Check macOS Focus mode isn't blocking them

### Cmd+U shortcut not working
- Enable Keyboard Shortcut in Settings
- Check whether another app has registered Cmd+U
- Disable/re-enable the shortcut or restart the app to register again

### Usage not updating
- App auto-refreshes every minute
- Click the refresh button to update manually
- If the cookie expired, sign in to Claude in Chrome again and click Detect Chrome Session

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

Installations upgraded with a saved cookie keep using it and skip automatic Chrome
checks. Click Detect Chrome Session to switch to automatic hourly sync.
