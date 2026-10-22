import 'dart:convert';
import 'dart:io';

import '../models/download_task.dart';

class DownloadQueueStore {
  Future<List<DownloadTask>> load() async {
    final file = await _queueFile();
    if (!await file.exists()) return [];

    final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
    return decoded
        .map((entry) => DownloadTask.fromJson(entry as Map<String, dynamic>))
        .toList();
  }

  Future<void> save(List<DownloadTask> tasks) async {
    final file = await _queueFile();
    await file.parent.create(recursive: true);
    final temporaryFile = File('${file.path}.tmp');
    final json = jsonEncode(tasks.map((task) => task.toJson()).toList());

    await temporaryFile.writeAsString(json, flush: true);
    await temporaryFile.rename(file.path);
  }

  Future<String> defaultDownloadDirectory() async {
    final home = _homeDirectory();
    return _join(home, 'Downloads');
  }

  Future<File> _queueFile() async {
    final appSupportDirectory = Platform.isWindows
        ? (Platform.environment['APPDATA'] ??
              _join(_homeDirectory(), 'AppData', 'Roaming'))
        : _join(_homeDirectory(), 'Library', 'Application Support');
    return File(
      _join(appSupportDirectory, 'InternetDownloadManager', 'downloads.json'),
    );
  }

  String _homeDirectory() {
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ?? Directory.current.path;
    }
    return Platform.environment['HOME'] ?? Directory.current.path;
  }

  String _join(String first, [String? second, String? third]) {
    final parts = [first, second, third].whereType<String>();
    return parts.join(Platform.pathSeparator);
  }
}
