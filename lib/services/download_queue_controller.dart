import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/download_task.dart';
import 'download_queue_store.dart';

class DownloadQueueController extends ChangeNotifier {
  DownloadQueueController(this._store);

  final DownloadQueueStore _store;
  List<DownloadTask> _tasks = [];
  bool _isLoading = true;
  String? _loadError;
  Future<void>? _loadFuture;
  Future<void> _mutationTail = Future<void>.value();

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  bool get isLoading => _isLoading;
  String? get loadError => _loadError;

  Future<void> load() => _loadFuture ??= _loadTasks();

  Future<void> _loadTasks() async {
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
    await load();
    if (_loadError != null) {
      throw StateError(
        'Cannot add a download because the saved queue failed to load.',
      );
    }
    final destinationDirectory = await _store.defaultDownloadDirectory();
    final task = DownloadTask.fromUrl(url, destinationDirectory);
    final result = Completer<DownloadTask>();
    _mutationTail = _mutationTail.then((_) async {
      final updatedTasks = [task, ..._tasks];
      try {
        await _store.save(updatedTasks);
        _tasks = updatedTasks;
        notifyListeners();
        result.complete(task);
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    await result.future;
    return task;
  }
}
