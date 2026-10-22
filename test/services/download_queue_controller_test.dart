import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:internet_download_manager/models/download_task.dart';
import 'package:internet_download_manager/services/download_queue_controller.dart';
import 'package:internet_download_manager/services/download_queue_store.dart';

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
}
