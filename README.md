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
supports them. Large files from servers that support HTTP Range are downloaded
in parallel segments. Segments resume only when the server supplies a matching
ETag or Last-Modified validator; when available, `If-Range` prevents combining
bytes from different versions of a remote file. If the server supplies no
validator, partial segments are discarded on the next attempt. Browser
integration is planned for a later phase.
