# LimitFuel for Linux and Windows

Claude and Codex plan usage in the Linux tray and the Windows notification area:
the percentage and reset time of each limit, a menu with every window, and
notifications at 25, 50, 75 and 90%.

## Install on Linux

Each release has three packages for x86_64:

| Package | For | Install |
| --- | --- | --- |
| `.deb` | Ubuntu, Debian, Mint, Pop!_OS | `sudo apt install ./LimitFuel_*_amd64.deb` |
| `.rpm` | Fedora, openSUSE, RHEL | `sudo dnf install ./LimitFuel-*.x86_64.rpm` |
| `.AppImage` | Any distribution with glibc 2.35 or later | `chmod +x LimitFuel_*.AppImage`, then run it |

There is no Flatpak or Snap: their sandboxes block reading the browser's cookie
database and starting the Codex CLI, which is how LimitFuel gets your usage.

## Desktop support

LimitFuel uses a StatusNotifierItem tray icon. Clicking it opens the menu.

| Desktop | Tray icon |
| --- | --- |
| KDE Plasma, Cinnamon, XFCE, Budgie, MATE, LXQt | Works |
| Ubuntu (GNOME with the Ubuntu AppIndicators extension) | Works |
| GNOME on Fedora, Debian and others | Install the "AppIndicator and KStatusNotifierItem Support" extension |
| Sway, Hyprland | Works with a bar that hosts tray items, such as Waybar |

When no tray host is running, LimitFuel opens its window instead and explains how
to get the icon.

## Connect

- **Claude:** Settings → Detect browser session reads your claude.ai session from
  Google Chrome, Chromium or Brave. Unlocking the keyring may need your password
  once. Background rechecks never prompt. You can paste a `Cookie` header instead;
  it is stored in your keyring (Secret Service), never in a file.
- **Codex:** install the Codex CLI and run `codex login` with ChatGPT. LimitFuel
  finds `codex` on your `PATH`, in `~/.local/bin`, `~/.npm-global/bin`,
  `/usr/local/bin` or `/usr/bin`; choose another path in Settings.

Not supported yet: KWallet (KDE users of Chrome can paste a cookie instead) and
Firefox.

## Windows (Beta)

`LimitFuel-Setup-x64.exe` installs LimitFuel for the current user, without
administrator rights, in `%LOCALAPPDATA%\LimitFuel`. It needs Windows 10 or 11
(x64) and installs Microsoft Edge WebView2 if it is missing.

The installer is not code-signed yet, so Microsoft Defender SmartScreen shows
"Windows protected your PC" the first time. Choose **More info**, then **Run
anyway**.

The icon sits in the notification area. Hover over it to see every limit; click
it for the menu.

- **Claude:** paste your `Cookie` header in Settings. In Chrome or Edge, open
  claude.ai, press F12, reload, select any request to claude.ai in the Network
  tab and copy its `Cookie` request header. It is kept in Windows Credential
  Manager, never in a file. Browser detection usually does not work on Windows:
  Chrome 127 and later encrypt cookies so that only the browser itself can read
  them (App-Bound Encryption), and browsers keep their cookie file locked while
  they run. LimitFuel does not work around either.
- **Codex:** install the Codex CLI (`npm install -g @openai/codex`) and run
  `codex login` with ChatGPT. LimitFuel finds `codex.exe` or `codex.cmd` on your
  `PATH` and in the usual npm, pnpm, Bun, Scoop and WinGet locations.

Settings are in `%APPDATA%\limitfuel\settings.json`. Open at login uses the
`LimitFuel` value under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`;
uninstalling removes it.

## Privacy

Settings are in `~/.config/limitfuel/settings.json` (mode 0600) and contain no
secrets. Error reports follow [the macOS policy](../docs/diagnostics.md): only the
provider and an error type, never cookies, accounts or usage. Turn them off in
Settings.

## Build

```bash
sudo apt install libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev build-essential file
```

```bash
cd linux && cargo test -p limitfuel-core
```

```bash
cd linux/app && npx --yes @tauri-apps/cli@2.12.3 build --bundles appimage,deb,rpm
```

On Windows (with the Visual Studio C++ build tools and Rust installed):

```bash
cd linux/app && npx --yes @tauri-apps/cli@2.12.3 build --bundles nsis
```

The core logic (`core/`) is plain Rust and its tests run on Linux, macOS and Windows.
[`SPEC.md`](SPEC.md) describes the behavior and what can go wrong.
