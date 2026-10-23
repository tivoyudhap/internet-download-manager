import 'dart:async';
import 'dart:io';

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
  bool _isDisposed = false;
  String? _activeTaskId;
  DownloadControl? _activeControl;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  bool get isLoading => _isLoading;
  String? get loadError => _loadError;

  Future<void> load() => _loadFuture ??= _loadTasks();

  Future<void> _loadTasks() async {
    _isLoading = true;
    _loadError = null;
    notifyListeners();
    try {
      final loadedTasks = await _store.load();
      _tasks = loadedTasks
          .map(
            (task) => task.status == DownloadStatus.downloading
                ? task.copyWith(
                    status: DownloadStatus.paused,
                    speedBytesPerSecond: 0,
                  )
                : task,
          )
          .toList();
      if (_tasks.indexed.any(
        (entry) => entry.$2.status != loadedTasks[entry.$1].status,
      )) {
        try {
          await _store.save(_tasks);
        } catch (_) {
          // Keep the recovered paused state available in memory.
        }
      }
    } catch (error) {
      _loadError = error.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<DownloadTask> addUrl(
    String url, {
    bool isStream = false,
    String? suggestedFileName,
    Map<String, String> requestHeaders = const {},
  }) async {
    await load();
    if (_loadError != null) {
      throw StateError(
        'Cannot add a download because the saved queue failed to load.',
      );
    }
    final destinationDirectory = await _store.defaultDownloadDirectory();
    final task = DownloadTask.fromUrl(
      url,
      destinationDirectory,
      isStream: isStream,
      suggestedFileName: suggestedFileName,
      requestHeaders: requestHeaders,
    );
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
          speedBytesPerSecond: 0,
          clearError: true,
        );
        await _replaceTask(task, persist: true);
        final control = DownloadControl();
        _activeTaskId = task.id;
        _activeControl = control;

        try {
          final result = await _engine.download(
            task,
            control: control,
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
          if (control.isCanceled) {
            final latestTask = _tasks.firstWhere(
              (queuedTask) => queuedTask.id == task.id,
              orElse: () => task,
            );
            await _replaceTask(
              latestTask.copyWith(
                status: DownloadStatus.canceled,
                speedBytesPerSecond: 0,
              ),
              persist: true,
            );
            continue;
          }
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
              status: error is DownloadCanceledException
                  ? DownloadStatus.canceled
                  : DownloadStatus.failed,
              speedBytesPerSecond: 0,
              errorMessage: error is DownloadCanceledException
                  ? null
                  : error.toString(),
              clearError: error is DownloadCanceledException,
            ),
            persist: true,
          );
        } finally {
          _activeTaskId = null;
          _activeControl = null;
        }
      }
    } finally {
      _persistTimer?.cancel();
      _persistTimer = null;
      _isProcessingQueue = false;
    }
  }

  Future<void> pauseDownload(String id) async {
    final task = _taskById(id);
    if (task == null ||
        task.status != DownloadStatus.downloading ||
        _activeTaskId != id ||
        _activeControl == null) {
      return;
    }
    await _replaceTask(
      task.copyWith(status: DownloadStatus.paused, speedBytesPerSecond: 0),
      persist: true,
    );
    _activeControl?.pause();
  }

  Future<void> resumeDownload(String id) async {
    final task = _taskById(id);
    if (task == null || task.status != DownloadStatus.paused) return;

    final control = _activeTaskId == id ? _activeControl : null;
    if (control == null) {
      await _replaceTask(
        task.copyWith(status: DownloadStatus.queued, clearError: true),
        persist: true,
      );
      await processQueue();
      return;
    }
    await _replaceTask(
      task.copyWith(status: DownloadStatus.downloading),
      persist: true,
    );
    control.resume();
  }

  Future<void> cancelDownload(String id) async {
    final task = _taskById(id);
    if (task == null ||
        task.status == DownloadStatus.completed ||
        task.status == DownloadStatus.failed ||
        task.status == DownloadStatus.canceled) {
      return;
    }
    if (_activeTaskId == id) _activeControl?.cancel();
    await _replaceTask(
      task.copyWith(status: DownloadStatus.canceled, speedBytesPerSecond: 0),
      persist: true,
    );
  }

  Future<void> retryDownload(String id) async {
    final task = _taskById(id);
    if (task == null ||
        (task.status != DownloadStatus.failed &&
            task.status != DownloadStatus.canceled)) {
      return;
    }
    await _replaceTask(
      task.copyWith(
        status: DownloadStatus.queued,
        clearError: true,
        clearProgress: true,
      ),
      persist: true,
    );
    await processQueue();
  }

  Future<void> clearHistory() async {
    await load();
    if (_loadError != null) {
      throw StateError(
        'Cannot clear history because the saved queue failed to load.',
      );
    }
    await _serialize(() async {
      final updatedTasks = _tasks
          .where(
            (task) =>
                task.status != DownloadStatus.completed &&
                task.status != DownloadStatus.failed &&
                task.status != DownloadStatus.canceled,
          )
          .toList();
      if (updatedTasks.length == _tasks.length) return;
      await _store.save(updatedTasks);
      _tasks = updatedTasks;
      notifyListeners();
    });
  }

  Future<void> removeHistoryItem(String id) async {
    await load();
    if (_loadError != null) {
      throw StateError(
        'Cannot clear history because the saved queue failed to load.',
      );
    }
    await _serialize(() async {
      final task = _taskById(id);
      if (task == null || !_isHistoryTask(task)) return;
      final updatedTasks = _tasks.where((item) => item.id != id).toList();
      await _store.save(updatedTasks);
      _tasks = updatedTasks;
      notifyListeners();
    });
  }

  Future<void> deleteDownloadedFile(String id) async {
    await load();
    if (_loadError != null) {
      throw StateError(
        'Cannot delete a file because the saved queue failed to load.',
      );
    }
    await _serialize(() async {
      final task = _taskById(id);
      if (task == null || task.status != DownloadStatus.completed) {
        throw StateError('Only completed downloads can be deleted.');
      }
      final file = File(
        '${task.destinationDirectory}${Platform.pathSeparator}${task.fileName}',
      );
      if (!await file.exists()) {
        throw FileSystemException('Downloaded file not found', file.path);
      }
      await file.delete();
      final updatedTasks = _tasks.where((item) => item.id != id).toList();
      await _store.save(updatedTasks);
      _tasks = updatedTasks;
      notifyListeners();
    });
  }

  bool _isHistoryTask(DownloadTask task) =>
      task.status == DownloadStatus.completed ||
      task.status == DownloadStatus.failed ||
      task.status == DownloadStatus.canceled;

  DownloadTask? _taskById(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  void _updateProgress(
    String id, {
    required int receivedBytes,
    required int? totalBytes,
    required double bytesPerSecond,
  }) {
    if (_isDisposed) return;
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
    if (_isDisposed) return;
    await _serialize(() async {
      if (_isDisposed) return;
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
    _isDisposed = true;
    _persistTimer?.cancel();
    _activeControl?.cancel();
    super.dispose();
  }
}
