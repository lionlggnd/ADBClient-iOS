# ADB Client for iOS

A native ADB client for iPhone and iPad, built with SwiftUI. It talks directly to `adbd` on your Android device over TCP/TLS: no computer and no adb server needed.

## Features

- **Connection**
  - Classic ADB over TCP: port 5555, after `adb tcpip 5555`. RSA authentication with the "Allow USB debugging?" prompt on the phone.
  - Wireless debugging (Android 11+): pairing with the 6-digit code (TLS + SPAKE2, the same protocol as `adb pair`), then an encrypted TLS connection.
  - Automatic mDNS discovery of `_adb-tls-pairing`, `_adb-tls-connect` and `_adb` services. List of recent devices.
- **Apps**
  - List with filters: user, system, disabled, removed and all. Search by package name.
  - Actions: launch, force stop, enable/disable, clear data, clear cache (Android 14+), trim the cache of all apps, suspend/unsuspend, uninstall, uninstall for user 0 (system apps too), restore a removed app, extract APK.
  - App details (version, SDK, dates, paths) and runtime permissions you can grant or revoke.
- **APK installation**: single APKs or split APKs (install-multiple), with the `-r -d -g -t` options.
- **Files**
  - File system browser over the sync protocol.
  - Download files and folders and share them. Upload from the Files app. Create folders, rename, delete. Install an APK that is already on the device.
- **Terminal** that works like platform-tools
  - Commands: `adb connect/pair/devices/shell/exec-out/logcat/install/install-multiple/uninstall/push/pull/reboot/root/unroot/remount/tcpip/usb/get-state/get-serialno/features`…
  - Interactive shell (PTY) with Ctrl-C, Ctrl-D, Tab, Esc and arrow keys.
  - Command history.
- **Settings**: key name, view and copy the public key, regenerate the key.

Local files used by push, pull and install, together with extracted APKs, live in the app's Documents folder (Files app > On My iPhone > ADB Client).

## Project structure

```
ADBClient/
  Native/        C on top of BoringSSL: RSA keys, sockets, TLS 1.3, SPAKE2 pairing
  Core/          ADB protocol (messages, connection, streams, sync), installer, mDNS
  Features/      SwiftUI screens (Device, Apps, Files, Terminal, Settings)
project.yml      XcodeGen project
scripts/build-boringssl.sh
.github/workflows/build-ipa.yml
```

## Build

The GitHub Actions workflow:

1. builds BoringSSL for iOS arm64 (cached);
2. generates the project with XcodeGen;
3. builds the app without code signing;
4. uploads `ADBClient-unsigned.ipa` as an artifact.

Built with Xcode 26: on iOS 26 the tab bar uses Liquid Glass. Requires iOS 16 or later.

The interface is in English, with an Italian translation (`ADBClient/Resources/it.lproj`) that iOS picks automatically when the device language is Italian.

## Installation

Download `ADBClient.ipa` from the [latest release](https://github.com/lionlggnd/ADBClient-iOS/releases/latest). The IPA is unsigned: install it with SideStore, AltStore or Sideloadly. With a free Apple ID the signature lasts 7 days.

Development builds of every commit are also available as artifacts of the GitHub Actions runs.

## Development

This project was developed with the help of an AI (Claude, by Anthropic) and is an early release. Bug reports are welcome in the Issues: please include your phone model and Android version.

## Known limitations

- iOS suspends network connections when the app goes to the background.
- `forward`, `reverse`, `sideload`, `backup` and `bugreport` are not supported.
- App display names are not available from the shell, so the package name is shown instead.

## License

Released under the [GPL-3.0](LICENSE) license. Third-party components (BoringSSL, Apache-2.0) are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Android is a trademark of Google LLC. This project is not affiliated with or endorsed by Google.
