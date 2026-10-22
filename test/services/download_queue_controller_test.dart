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

  test('resuming a saved paused task starts a fresh transfer', () async {
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
