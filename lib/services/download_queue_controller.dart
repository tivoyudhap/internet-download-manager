import 'package:flutter/foundation.dart';

import '../models/download_task.dart';
import 'download_queue_store.dart';

class DownloadQueueController extends ChangeNotifier {
  DownloadQueueController(this._store);

  final DownloadQueueStore _store;
  List<DownloadTask> _tasks = [];
  bool _isLoading = true;
  String? _loadError;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  bool get isLoading => _isLoading;
  String? get loadError => _loadError;

  Future<void> load() async {
    _isLoading = true;
    _loadError = null;
    notifyListeners();
    try {
      _tasks = await _store.load();
    } catch (error) {
      _loadError = error.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<DownloadTask> addUrl(String url) async {
    final destinationDirectory = await _store.defaultDownloadDirectory();
    final task = DownloadTask.fromUrl(url, destinationDirectory);
    final updatedTasks = [task, ..._tasks];
    await _store.save(updatedTasks);
    _tasks = updatedTasks;
    notifyListeners();
    return task;
  }
}
