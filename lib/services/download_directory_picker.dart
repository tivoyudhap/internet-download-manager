import 'package:flutter/services.dart';

class DownloadDirectoryPicker {
  const DownloadDirectoryPicker();

  static const _channel = MethodChannel(
    'internet_download_manager/download_directory',
  );

  Future<String?> pickDirectory() {
    return _channel.invokeMethod<String>('pickDirectory');
  }

  Future<void> clearAccess() {
    return _channel.invokeMethod<void>('clearAccess');
  }
}
