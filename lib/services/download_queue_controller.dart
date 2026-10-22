import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/download_task.dart';
import 'download_engine.dart';
import 'download_queue_store.dart';

class DownloadQueueController extends ChangeNotifier {
  DownloadQueueController(this._store, {DownloadEngine? engine})
    : _engine = engine ?? HttpDownloadEngine();

  final DownloadQueueStore _store;
  final DownloadEngine _engine;
  List<DownloadTask> _tasks = [];
  bool _isLoading = true;
  String? _loadError;
  Future<void>? _loadFuture;
  Future<void> _mutationTail = Future<void>.value();
  Timer? _persistTimer;
  bool _isProcessingQueue = false;

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
    await _serialize(() async {
      final updatedTasks = [task, ..._tasks];
      await _store.save(updatedTasks);
      _tasks = updatedTasks;
      notifyListeners();
    });
    return task;
  }

  Future<void> processQueue() async {
    await load();
    if (_isProcessingQueue || _loadError != null) return;

    _isProcessingQueue = true;
    try {
      while (true) {
        final nextIndex = _tasks.indexWhere(
          (task) => task.status == DownloadStatus.queued,
        );
        if (nextIndex == -1) break;
        var task = _tasks[nextIndex];
        task = task.copyWith(
          status: DownloadStatus.downloading,
          receivedBytes: 0,
          speedBytesPerSecond: 0,
          clearError: true,
        );
        await _replaceTask(task, persist: true);

        try {
          final result = await _engine.download(
            task,
            onProgress:
                ({
                  required receivedBytes,
                  required totalBytes,
                  required bytesPerSecond,
                }) {
                  _updateProgress(
                    task.id,
                    receivedBytes: receivedBytes,
                    totalBytes: totalBytes,
                    bytesPerSecond: bytesPerSecond,
                  );
                },
          );
          await _replaceTask(
            task.copyWith(
              fileName: result.fileName,
              status: DownloadStatus.completed,
              totalBytes: result.totalBytes,
              receivedBytes: result.totalBytes,
              speedBytesPerSecond: 0,
            ),
            persist: true,
          );
        } catch (error) {
          final latestTask = _tasks.firstWhere(
            (queuedTask) => queuedTask.id == task.id,
            orElse: () => task,
          );
          await _replaceTask(
            latestTask.copyWith(
              status: DownloadStatus.failed,
              speedBytesPerSecond: 0,
              errorMessage: error.toString(),
            ),
            persist: true,
          );
        }
      }
    } finally {
      _persistTimer?.cancel();
      _persistTimer = null;
      _isProcessingQueue = false;
    }
  }

  void _updateProgress(
    String id, {
    required int receivedBytes,
    required int? totalBytes,
    required double bytesPerSecond,
  }) {
    final index = _tasks.indexWhere((task) => task.id == id);
    if (index == -1) return;
    _tasks[index] = _tasks[index].copyWith(
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
      speedBytesPerSecond: bytesPerSecond,
    );
    notifyListeners();
    _persistTimer ??= Timer(const Duration(seconds: 1), () {
      _persistTimer = null;
      _persistCurrentQueue();
    });
  }

  Future<void> _persistCurrentQueue() async {
    try {
      await _serialize(() => _store.save(List.of(_tasks)));
    } catch (_) {
      // Progress remains visible in memory; terminal state saves report errors.
    }
  }

  Future<void> _replaceTask(
    DownloadTask updatedTask, {
    required bool persist,
  }) async {
    await _serialize(() async {
      final updatedTasks = List<DownloadTask>.of(_tasks);
      final index = updatedTasks.indexWhere(
        (task) => task.id == updatedTask.id,
      );
      if (index == -1) return;
      updatedTasks[index] = updatedTask;
      if (persist) await _store.save(updatedTasks);
      _tasks = updatedTasks;
      notifyListeners();
    });
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = Completer<void>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        await operation();
        result.complete();
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    super.dispose();
  }
}
