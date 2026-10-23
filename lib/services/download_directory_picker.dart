import 'package:flutter/services.dart';

class DownloadDirectoryPicker {
  static const _channel = MethodChannel(
    'internet_download_manager/download_directory',
  );

  static Future<String?> pickDirectory() {
    return _channel.invokeMethod<String>('pickDirectory');
  }

  static Future<void> clearAccess() {
    return _channel.invokeMethod<void>('clearAccess');
  }
}
