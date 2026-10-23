import 'dart:convert';
import 'dart:io';

import '../models/download_task.dart';

class DownloadQueueStore {
  DownloadQueueStore({this.supportDirectory, this.homeDirectory});

  final Directory? supportDirectory;
  final Directory? homeDirectory;

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
    final configured = await configuredDownloadDirectory();
    if (configured != null) return configured;
    final home = (homeDirectory ?? Directory(_homeDirectory())).path;
    return _join(home, 'Downloads');
  }

  Future<String?> configuredDownloadDirectory() async {
    final file = await _settingsFile();
    if (!await file.exists()) return null;
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final directory = decoded['downloadDirectory'] as String?;
    return directory == null || directory.trim().isEmpty ? null : directory;
  }

  Future<void> saveDownloadDirectory(String? directory) async {
    final file = await _settingsFile();
    if (directory == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    final temporaryFile = File('${file.path}.tmp');
    await temporaryFile.writeAsString(
      jsonEncode({'downloadDirectory': directory}),
      flush: true,
    );
    await temporaryFile.rename(file.path);
  }

  Future<File> browserBridgeTokenFile() async {
    final queueFile = await _queueFile();
    return File(_join(queueFile.parent.path, 'browser_bridge.token'));
  }

  Future<File> _queueFile() async {
    final appSupportPath = supportDirectory?.path;
    final appSupportDirectory =
        appSupportPath ??
        (Platform.isWindows
            ? (Platform.environment['APPDATA'] ??
                  _join(_homeDirectory(), 'AppData', 'Roaming'))
            : _join(_homeDirectory(), 'Library', 'Application Support'));
    return File(
      _join(appSupportDirectory, 'InternetDownloadManager', 'downloads.json'),
    );
  }

  Future<File> _settingsFile() async {
    final queueFile = await _queueFile();
    return File(_join(queueFile.parent.path, 'settings.json'));
  }

  String _homeDirectory() {
    if (homeDirectory != null) return homeDirectory!.path;
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
