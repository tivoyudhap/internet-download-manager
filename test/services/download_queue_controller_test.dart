import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:internet_download_manager/models/download_task.dart';
import 'package:internet_download_manager/services/download_engine.dart';
import 'package:internet_download_manager/services/download_queue_controller.dart';
import 'package:internet_download_manager/services/download_queue_store.dart';

class _TestDownloadEngine implements DownloadEngine {
  _TestDownloadEngine({this.failure});

  final String? failure;

  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
    DownloadControl? control,
  }) async {
    onProgress(receivedBytes: 512, totalBytes: 1024, bytesPerSecond: 256);
    if (failure != null) throw DownloadException(failure!);
    return DownloadResult(fileName: task.fileName, totalBytes: 1024);
  }
}

class _FailingSaveStore extends DownloadQueueStore {
  @override
  Future<List<DownloadTask>> load() async => [];

  @override
  Future<String> defaultDownloadDirectory() async => '/tmp/Downloads';

  @override
  Future<void> save(List<DownloadTask> tasks) async {
    throw const FileSystemException('disk is unavailable');
  }
}

class _ControlledDownloadEngine implements DownloadEngine {
  final started = Completer<void>();
  final finish = Completer<void>();

  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
    DownloadControl? control,
  }) async {
    onProgress(receivedBytes: 256, totalBytes: 1024, bytesPerSecond: 128);
    started.complete();
    await finish.future;
    await control?.waitUntilResumed();
    return DownloadResult(fileName: task.fileName, totalBytes: 1024);
  }
}

class _CancelAwareDownloadEngine implements DownloadEngine {
  final started = Completer<void>();
  bool wasCanceled = false;

  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
    DownloadControl? control,
  }) async {
    started.complete();
    await control!.whenCanceled;
    wasCanceled = true;
    throw const DownloadCanceledException();
  }
}

class _FailOnceDownloadEngine implements DownloadEngine {
  int calls = 0;

  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
    DownloadControl? control,
  }) async {
    calls++;
    if (calls == 1) throw const DownloadException('temporary failure');
    return DownloadResult(fileName: task.fileName, totalBytes: 64);
  }
}

class _RecordingDownloadEngine implements DownloadEngine {
  final downloadedIds = <String>[];

  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
    DownloadControl? control,
  }) async {
    downloadedIds.add(task.id);
    return DownloadResult(fileName: task.fileName, totalBytes: 42);
  }
}

void main() {
  late Directory temporaryDirectory;
  late DownloadQueueStore store;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp('idm-queue-');
    store = DownloadQueueStore(
      supportDirectory: Directory('${temporaryDirectory.path}/support'),
      homeDirectory: Directory('${temporaryDirectory.path}/home'),
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('loads persisted tasks into the queue', () async {
    final savedTask = DownloadTask.fromUrl(
      'https://example.com/saved.pdf',
      '/tmp/Downloads',
    );
    await store.save([savedTask]);
    final controller = DownloadQueueController(store);
    addTearDown(controller.dispose);

    await controller.load();

    expect(controller.isLoading, isFalse);
    expect(controller.loadError, isNull);
    expect(controller.tasks.single.id, savedTask.id);
  });

  test('recovers an interrupted download as paused on startup', () async {
    final interruptedTask = DownloadTask(
      id: 'interrupted-task',
      url: 'https://example.com/file.zip',
      fileName: 'file.zip',
      destinationDirectory: '/tmp/Downloads',
      status: DownloadStatus.downloading,
      createdAt: DateTime.utc(2026),
      totalBytes: 2048,
      receivedBytes: 512,
      speedBytesPerSecond: 128,
    );
    await store.save([interruptedTask]);
    final controller = DownloadQueueController(store);
    addTearDown(controller.dispose);

    await controller.load();

    expect(controller.tasks.single.status, DownloadStatus.paused);
    expect(controller.tasks.single.receivedBytes, 512);
    expect(controller.tasks.single.speedBytesPerSecond, 0);
    final saved = (await store.load()).single;
    expect(saved.status, DownloadStatus.paused);
    expect(saved.receivedBytes, 512);
  });

  test('adding a URL persists it and notifies listeners', () async {
    final controller = DownloadQueueController(store);
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);
    await controller.load();
    notifications = 0;

    final task = await controller.addUrl('https://example.com/new-file.zip');
    final restored = await store.load();

    expect(controller.tasks, hasLength(1));
    expect(controller.tasks.single.id, task.id);
    expect(controller.tasks.single.fileName, 'new-file.zip');
    expect(controller.tasks.single.status, DownloadStatus.queued);
    expect(restored.single.id, task.id);
    expect(notifications, 1);
  });

  test('new tasks use the selected download directory', () async {
    const selectedDirectory = '/tmp/Custom Download Folder';
    await store.saveDownloadDirectory(selectedDirectory);
    final controller = DownloadQueueController(store);
    addTearDown(controller.dispose);

    final task = await controller.addUrl('https://example.com/new-file.zip');

    expect(task.destinationDirectory, selectedDirectory);
    expect((await store.load()).single.destinationDirectory, selectedDirectory);
  });

  test(
    'clears terminal history and preserves queued or paused tasks',
    () async {
      DownloadTask task(String name, DownloadStatus status) =>
          DownloadTask.fromUrl(
            'https://example.com/$name.zip',
            '/tmp/Downloads',
          ).copyWith(status: status);
      await store.save([
        task('done', DownloadStatus.completed),
        task('broken', DownloadStatus.failed),
        task('stopped', DownloadStatus.canceled),
        task('waiting', DownloadStatus.queued),
        task('paused', DownloadStatus.paused),
      ]);
      final controller = DownloadQueueController(store);
      addTearDown(controller.dispose);
      await controller.load();

      await controller.clearHistory();

      expect(controller.tasks.map((task) => task.fileName), [
        'waiting.zip',
        'paused.zip',
      ]);
      expect((await store.load()).map((task) => task.fileName), [
        'waiting.zip',
        'paused.zip',
      ]);
    },
  );

  test('removing one history entry keeps its downloaded file', () async {
    final directory = Directory('${temporaryDirectory.path}/Downloads');
    await directory.create(recursive: true);
    final downloadedFile = File('${directory.path}/finished.zip');
    await downloadedFile.writeAsBytes([1, 2, 3]);
    final task = DownloadTask(
      id: 'finished-file',
      url: 'https://example.com/finished.zip',
      fileName: 'finished.zip',
      destinationDirectory: directory.path,
      status: DownloadStatus.completed,
      createdAt: DateTime.utc(2026),
    );
    await store.save([task]);
    final controller = DownloadQueueController(store);
    addTearDown(controller.dispose);
    await controller.load();

    await controller.removeHistoryItem(task.id);

    expect(controller.tasks, isEmpty);
    expect(await store.load(), isEmpty);
    expect(await downloadedFile.exists(), isTrue);
  });

  test(
    'deleting a completed file removes only its own history entry',
    () async {
      final directory = Directory('${temporaryDirectory.path}/Downloads');
      await directory.create(recursive: true);
      final downloadedFile = File('${directory.path}/finished.zip');
      await downloadedFile.writeAsBytes([1, 2, 3]);
      final completedTask = DownloadTask(
        id: 'finished-file',
        url: 'https://example.com/finished.zip',
        fileName: 'finished.zip',
        destinationDirectory: directory.path,
        status: DownloadStatus.completed,
        createdAt: DateTime.utc(2026),
      );
      final queuedTask = DownloadTask.fromUrl(
        'https://example.com/waiting.zip',
        directory.path,
      );
      await store.save([completedTask, queuedTask]);
      final controller = DownloadQueueController(store);
      addTearDown(controller.dispose);
      await controller.load();

      await controller.deleteDownloadedFile(completedTask.id);

      expect(await downloadedFile.exists(), isFalse);
      expect(controller.tasks.map((task) => task.id), [queuedTask.id]);
      expect((await store.load()).map((task) => task.id), [queuedTask.id]);
    },
  );

  test('does not delete a missing file or a non-completed download', () async {
    final completedTask = DownloadTask(
      id: 'missing-file',
      url: 'https://example.com/missing.zip',
      fileName: 'missing.zip',
      destinationDirectory: temporaryDirectory.path,
      status: DownloadStatus.completed,
      createdAt: DateTime.utc(2026),
    );
    final queuedTask = DownloadTask.fromUrl(
      'https://example.com/waiting.zip',
      '/tmp/Downloads',
    );
    await store.save([completedTask, queuedTask]);
    final controller = DownloadQueueController(store);
    addTearDown(controller.dispose);
    await controller.load();

    await expectLater(
      controller.deleteDownloadedFile(completedTask.id),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      controller.deleteDownloadedFile(queuedTask.id),
      throwsA(isA<StateError>()),
    );

    expect(controller.tasks.map((task) => task.id), [
      completedTask.id,
      queuedTask.id,
    ]);
  });

  test('concurrent additions are both retained in storage', () async {
    final controller = DownloadQueueController(store);
    addTearDown(controller.dispose);
    await controller.load();

    final tasks = await Future.wait([
      controller.addUrl('https://example.com/first.zip'),
      controller.addUrl('https://example.com/second.zip'),
    ]);
    final restored = await store.load();

    expect(controller.tasks, hasLength(2));
    expect(restored, hasLength(2));
    expect(restored.map((task) => task.id).toSet(), {tasks[0].id, tasks[1].id});
  });

  test('keeps same-name downloads as separate queue entries', () async {
    final controller = DownloadQueueController(store);
    addTearDown(controller.dispose);
    await controller.load();

    await Future.wait([
      controller.addUrl('https://one.example.com/shared.zip'),
      controller.addUrl('https://two.example.com/shared.zip'),
    ]);

    expect(controller.tasks, hasLength(2));
    expect(controller.tasks.map((task) => task.fileName), [
      'shared.zip',
      'shared.zip',
    ]);
    expect(controller.tasks.map((task) => task.id).toSet(), hasLength(2));
  });

  test('does not add a task when saving fails', () async {
    final controller = DownloadQueueController(_FailingSaveStore());
    addTearDown(controller.dispose);
    await controller.load();

    await expectLater(
      controller.addUrl('https://example.com/file.zip'),
      throwsA(isA<FileSystemException>()),
    );

    expect(controller.tasks, isEmpty);
  });

  test('does not overwrite a queue that failed to load', () async {
    final queueFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}support${Platform.pathSeparator}InternetDownloadManager${Platform.pathSeparator}downloads.json',
    );
    await queueFile.parent.create(recursive: true);
    const corruptContents = '{bad json';
    await queueFile.writeAsString(corruptContents);
    final controller = DownloadQueueController(store);
    addTearDown(controller.dispose);

    await controller.load();
    await expectLater(
      controller.addUrl('https://example.com/new.zip'),
      throwsA(isA<StateError>()),
    );

    expect(controller.tasks, isEmpty);
    expect(await queueFile.readAsString(), corruptContents);
  });

  test('processes a queued task and persists transfer progress', () async {
    final controller = DownloadQueueController(
      store,
      engine: _TestDownloadEngine(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final task = await controller.addUrl('https://example.com/file.zip');
    final receivedByteUpdates = <int>[];
    controller.addListener(() {
      final updatedTask = controller.tasks.firstWhere(
        (item) => item.id == task.id,
      );
      receivedByteUpdates.add(updatedTask.receivedBytes);
    });

    await controller.processQueue();

    final completed = controller.tasks.single;
    expect(receivedByteUpdates, contains(512));
    expect(completed.status, DownloadStatus.completed);
    expect(completed.receivedBytes, 1024);
    expect(completed.totalBytes, 1024);
    expect((await store.load()).single.status, DownloadStatus.completed);
  });

  test('marks an HTTP failure and stores its message', () async {
    final controller = DownloadQueueController(
      store,
      engine: _TestDownloadEngine(failure: 'Server returned HTTP 404.'),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.addUrl('https://example.com/missing.zip');

    await controller.processQueue();

    expect(controller.tasks.single.status, DownloadStatus.failed);
    expect(controller.tasks.single.errorMessage, 'Server returned HTTP 404.');
    expect((await store.load()).single.status, DownloadStatus.failed);
  });

  test('processes queued downloads one at a time in queue order', () async {
    final engine = _RecordingDownloadEngine();
    final controller = DownloadQueueController(store, engine: engine);
    addTearDown(controller.dispose);
    await controller.load();
    final first = await controller.addUrl('https://example.com/first.zip');
    final second = await controller.addUrl('https://example.com/second.zip');

    await controller.processQueue();

    expect(engine.downloadedIds, [second.id, first.id]);
    expect(
      controller.tasks.map((task) => task.status),
      everyElement(DownloadStatus.completed),
    );
  });

  test('ignores a concurrent request to process an active queue', () async {
    final engine = _ControlledDownloadEngine();
    final controller = DownloadQueueController(store, engine: engine);
    addTearDown(controller.dispose);
    await controller.load();
    await controller.addUrl('https://example.com/file.zip');

    final processing = controller.processQueue();
    await engine.started.future;
    await controller.processQueue();
    expect(controller.tasks.single.status, DownloadStatus.downloading);

    engine.finish.complete();
    await processing;
    expect(controller.tasks.single.status, DownloadStatus.completed);
  });

  test('pauses and resumes an active download', () async {
    final engine = _ControlledDownloadEngine();
    final controller = DownloadQueueController(store, engine: engine);
    addTearDown(controller.dispose);
    await controller.load();
    final task = await controller.addUrl('https://example.com/file.zip');
    final processing = controller.processQueue();
    await engine.started.future;

    await controller.pauseDownload(task.id);
    expect(controller.tasks.single.status, DownloadStatus.paused);
    expect((await store.load()).single.status, DownloadStatus.paused);

    await controller.resumeDownload(task.id);
    expect(controller.tasks.single.status, DownloadStatus.downloading);
    engine.finish.complete();
    await processing;
    expect(controller.tasks.single.status, DownloadStatus.completed);
  });

  test('cancels an active download and persists the canceled state', () async {
    final engine = _ControlledDownloadEngine();
    final controller = DownloadQueueController(store, engine: engine);
    addTearDown(controller.dispose);
    await controller.load();
    final task = await controller.addUrl('https://example.com/file.zip');
    final processing = controller.processQueue();
    await engine.started.future;

    await controller.cancelDownload(task.id);
    expect(controller.tasks.single.status, DownloadStatus.canceled);
    engine.finish.complete();
    await processing;
    expect((await store.load()).single.status, DownloadStatus.canceled);
  });

  test(
    'disposing the controller stops active work for background app exit',
    () async {
      final engine = _CancelAwareDownloadEngine();
      final controller = DownloadQueueController(store, engine: engine);
      await controller.load();
      await controller.addUrl('https://example.com/file.zip');
      final processing = controller.processQueue();
      await engine.started.future;

      controller.dispose();
      await processing;

      expect(engine.wasCanceled, isTrue);
      final recoveredController = DownloadQueueController(store);
      addTearDown(recoveredController.dispose);
      await recoveredController.load();
      expect(recoveredController.tasks.single.status, DownloadStatus.paused);
    },
  );

  test('cancels a queued task without starting the engine', () async {
    final engine = _FailOnceDownloadEngine();
    final controller = DownloadQueueController(store, engine: engine);
    addTearDown(controller.dispose);
    await controller.load();
    final task = await controller.addUrl('https://example.com/file.zip');

    await controller.cancelDownload(task.id);

    expect(controller.tasks.single.status, DownloadStatus.canceled);
    expect(engine.calls, 0);
    expect((await store.load()).single.status, DownloadStatus.canceled);
  });

  test('retrying a canceled task queues a clean new attempt', () async {
    final engine = _TestDownloadEngine();
    final controller = DownloadQueueController(store, engine: engine);
    addTearDown(controller.dispose);
    await controller.load();
    final task = await controller.addUrl('https://example.com/file.zip');
    await controller.cancelDownload(task.id);

    await controller.retryDownload(task.id);

    expect(controller.tasks.single.status, DownloadStatus.completed);
    expect(controller.tasks.single.receivedBytes, 1024);
  });

  test('resuming a saved paused task keeps its partial progress', () async {
    final pausedTask = DownloadTask(
      id: 'paused-task',
      url: 'https://example.com/file.zip',
      fileName: 'file.zip',
      destinationDirectory: '/tmp/Downloads',
      status: DownloadStatus.paused,
      createdAt: DateTime.utc(2026),
      totalBytes: 1024,
      receivedBytes: 512,
      speedBytesPerSecond: 128,
    );
    await store.save([pausedTask]);
    final controller = DownloadQueueController(
      store,
      engine: _TestDownloadEngine(),
    );
    addTearDown(controller.dispose);
    await controller.load();

    await controller.resumeDownload(pausedTask.id);

    expect(controller.tasks.single.status, DownloadStatus.completed);
    expect(controller.tasks.single.receivedBytes, 1024);
  });

  test(
    'retries a failed task with cleared error and transfer progress',
    () async {
      final engine = _FailOnceDownloadEngine();
      final controller = DownloadQueueController(store, engine: engine);
      addTearDown(controller.dispose);
      await controller.load();
      final task = await controller.addUrl('https://example.com/file.zip');
      await controller.processQueue();
      expect(controller.tasks.single.status, DownloadStatus.failed);

      await controller.retryDownload(task.id);

      final retried = controller.tasks.single;
      expect(engine.calls, 2);
      expect(retried.status, DownloadStatus.completed);
      expect(retried.errorMessage, isNull);
      expect(retried.receivedBytes, 64);
    },
  );
}
