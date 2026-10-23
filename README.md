# Internet Download Manager

Cross-platform desktop download manager built with Flutter for macOS and Windows.

## Requirements

- Flutter SDK (stable)
- macOS build: macOS with Xcode or Xcode Command Line Tools
- Windows build: Windows with Visual Studio and the **Desktop development with C++** workload

## Run

```sh
flutter pub get
flutter run -d macos
```

On Windows, use `flutter run -d windows`. Build release versions with `flutter build macos` or `flutter build windows` on the matching operating system.

## GitHub releases

The app version is defined in `pubspec.yaml`. Pushing a version tag such as
`v1.0.0` starts the GitHub Actions release workflow. It builds a macOS `.dmg`
and a Windows setup `.exe`, then attaches both files to a GitHub Release for
that tag. Both packages include the native messaging host. The Windows `.exe`
installs it with the complete Flutter app bundle for the current user. The
macOS DMG includes a **Register Chrome Host** helper; Windows adds a matching
Start Menu shortcut. After installing the Chrome extension separately, run the
helper and enter the extension ID shown at `chrome://extensions`, then restart
Chrome. Chrome requires the native host registration to allow that specific
extension ID.

The first-party release packages are unsigned. macOS Gatekeeper or Windows
SmartScreen may show an unidentified developer warning; code signing and
notarization require developer credentials configured in GitHub Actions.

Closing the main window keeps the app running in the macOS menu bar or Windows
system tray. Use **Buka Internet Download Manager** to restore it, or **Keluar**
to stop the app and its active downloads.

Video stream downloads use FFmpeg. Install an `ffmpeg` build that includes HLS
and DASH input demuxers on the target computer and make sure it is available on
`PATH`. The Chrome extension requests access to all sites so it can detect HLS
(`.m3u8`) and DASH (`.mpd`) manifests; captured session headers are held in
memory and are not written to the saved queue. DRM-protected streams are not
supported.

## Google Chrome extension (development)

The unpacked extension adds **Download with IDM** to link, video, audio, and
image context menus in Google Chrome. The desktop app must be open to receive
downloads.

1. Open `chrome://extensions`, enable Developer mode, choose **Load unpacked**,
   and select `browser/chrome`.
2. Copy the extension ID shown on that page.
3. Compile the native messaging host on the target OS and register it for the
   extension ID.

On macOS:

```sh
mkdir -p build
dart compile exe browser/native_host/bin/idm_native_host.dart -o build/idm_native_host
sh browser/setup_chrome_host_macos.sh "$PWD/build/idm_native_host" EXTENSION_ID
```

On Windows, from PowerShell:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
dart compile exe browser/native_host/bin/idm_native_host.dart -o build/idm_native_host.exe
.\browser\setup_chrome_host_windows.ps1 -HostPath (Resolve-Path .\build\idm_native_host.exe) -ExtensionId EXTENSION_ID
```

Restart the browser and keep Internet Download Manager open. Right-click an
HTTP or HTTPS link or media item, then choose **Download with IDM**. Chrome
connects to a small native messaging host, which forwards the URL to the open
Flutter app over a local authenticated bridge.

## Project status

The macOS and Windows Flutter desktop app includes a persisted download queue,
HTTP/HTTPS downloads, transfer progress, pause, resume, cancel, and retry
actions. Interrupted transfers resume with HTTP Range requests when the server
supports them. Large files from servers that support HTTP Range are downloaded
in parallel segments. Segments resume only when the server supplies a matching
ETag or Last-Modified validator; when available, `If-Range` prevents combining
bytes from different versions of a remote file. If the server supplies no
validator, partial segments are discarded on the next attempt. Chrome browser
integration is available as a development extension.
