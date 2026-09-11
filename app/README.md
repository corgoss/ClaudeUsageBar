# ClaudeUsageBar

> Track your Claude.ai usage right from your Mac menu bar!

A lightweight macOS menu bar app that displays your Claude.ai session and weekly usage limits with real-time updates and notifications.

## ✨ Features

- 🟢 **Real-time Usage Tracking**: Monitor session (5-hour) and weekly (7-day) usage
- 👥 **Multiple Accounts**: Add several Claude accounts and switch the active one from the popover or menu bar
- 🎨 **Color-Coded Menu Bar Icon**: Visual indication of usage levels (green/yellow/red)
- 🔔 **Smart Notifications**: Alerts at 25%, 50%, 75%, and 90% usage thresholds
- ⚡ **Auto-Refresh**: Updates every 5 minutes automatically
- ⌨️ **Keyboard Shortcut**: Toggle popup with Cmd+U from anywhere
- 🔒 **Privacy First**: All data stored locally on your Mac
- 📊 **Pro Plan Support**: Shows weekly Sonnet usage for Pro subscribers
- 🎯 **Menu Bar Only**: No Dock icon, stays out of your way

## 🖼️ Screenshots

**Menu Bar Display:**
- Shows current session percentage with color-coded emoji
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

### Option 1: DMG Installer (Recommended)

1. Download `ClaudeUsageBar-Installer.dmg` from [Releases](../../releases)
2. Double-click the DMG file
3. Drag ClaudeUsageBar to the Applications folder
4. Eject the DMG
5. Open ClaudeUsageBar from Applications

### Option 2: ZIP Archive

1. Download `ClaudeUsageBar.zip` from [Releases](../../releases)
2. Extract the ZIP file
3. Drag ClaudeUsageBar.app to Applications folder
4. Open ClaudeUsageBar from Applications

### Option 3: Build from Source

```bash
cd app
chmod +x build.sh
./build.sh
```

The built app will be in `build/ClaudeUsageBar.app`.

## 📦 Set Up (10 seconds)

1. Launch ClaudeUsageBar
2. Click **Sign in with Claude**
3. Sign in normally - Google or email both work

Your session is stored in the macOS Keychain. Add more accounts the same way;
each is kept separate, so there's no need for separate browsers. Existing pasted
cookies are migrated automatically when you upgrade. Downgrading to an older
version requires signing in again.

## ⚙️ Settings

Access settings by clicking the gear icon in the popup:

### Notifications
- Enable/disable usage alerts
- Get notifications at 25%, 50%, 75%, 90% thresholds
- Enable daily reminders when a Claude sign-in is close to expiring
- Click "Test Notification" to verify it works

### Keyboard Shortcut (Cmd+U)
- Toggle popup from anywhere on your Mac
- Requires Accessibility permission
- Click "Enable Keyboard Shortcut" to grant permission

### Launch at Login
- Start ClaudeUsageBar automatically when you log in

## 🔒 Privacy & Security

- ✅ **All data stays on your Mac** - account metadata is in UserDefaults and sessions are in the macOS Keychain
- ✅ **No analytics or tracking** - zero external services
- ✅ **Session cookies stored locally** - never sent anywhere except claude.ai
- ✅ **No hardcoded credentials** - org ID extracted dynamically from your cookie
- ✅ **Open source** - review the code yourself

## 🎯 How It Works

1. Opens the real claude.ai sign-in page for Google or email authentication
2. Fetches usage data from the same endpoints the website uses
3. Keeps each account's authenticated session in a separate Keychain-backed cookie jar
4. Displays real-time usage in your menu bar
5. Sends notifications when you hit usage thresholds

## 🔨 Building & Distribution

### First-time setup (one command)
```bash
../scripts/create_dev_cert.sh
```
Creates a self-signed code-signing certificate so local builds have a stable
identity. Without it `build.sh` falls back to ad-hoc signing, and because a
keychain ACL is matched against the app's designated requirement — which for an
ad-hoc signature is the binary's own hash — **every rebuild loses access to the
saved session and macOS prompts for your keychain password again**. Skip this
step only if you have the Developer ID certificate installed.

### Build the App
```bash
./build.sh
```

### Create DMG Installer
```bash
./create_dmg.sh
```

### Clean Build
```bash
rm -rf build
./build.sh
```

## 🐛 Troubleshooting

### "No data yet" showing
- Make sure you have signed in with Claude
- Click the refresh button to fetch usage again
- Sign in again if the account needs attention

### Sign-in expired
- Claude sessions expire periodically
- Click **Sign in again** on the affected account
- Complete normal Google or email sign-in to restore tracking

### Notifications not working
- Click "Test Notification" in Settings
- Notifications work without permission prompts
- Check macOS Focus mode isn't blocking them

### Cmd+U shortcut not working
- Click "Enable Keyboard Shortcut" in Settings
- Grant Accessibility permission in System Settings
- Restart the app after granting permission

### Usage not updating
- App auto-refreshes every 5 minutes
- Click the refresh button to update manually
- If the session expired, sign in again

## 📦 Distribution Files

- **ClaudeUsageBar-Installer.dmg** - Drag-to-install DMG (1.6 MB)
- **README.md** - This file
- **LICENSE** - MIT License

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
