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

## Project status

The macOS and Windows Flutter desktop app includes a persisted download queue,
HTTP/HTTPS downloads, transfer progress, pause, resume, cancel, and retry
actions. Interrupted transfers resume with HTTP Range requests when the server
supports them. Browser integration and segmented downloads are planned for
later phases.
