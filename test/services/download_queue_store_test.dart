import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:internet_download_manager/models/download_task.dart';
import 'package:internet_download_manager/services/download_queue_store.dart';

void main() {
  late Directory temporaryDirectory;
  late DownloadQueueStore store;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp('idm-store-');
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

  test('loads an empty queue when no saved queue exists', () async {
    expect(await store.load(), isEmpty);
  });

  test('saves and restores queued tasks', () async {
    final tasks = [
      DownloadTask.fromUrl(
        'https://example.com/file.zip',
        '${temporaryDirectory.path}/home/Downloads',
      ),
    ];

    await store.save(tasks);
    final restored = await store.load();

    expect(restored, hasLength(1));
    expect(restored.single.id, tasks.single.id);
    expect(restored.single.url, tasks.single.url);
    expect(restored.single.fileName, 'file.zip');
    expect(restored.single.status, DownloadStatus.queued);
  });

  test('replaces the previously saved queue', () async {
    final first = DownloadTask.fromUrl(
      'https://example.com/first.zip',
      '/tmp/Downloads',
    );
    final second = DownloadTask.fromUrl(
      'https://example.com/second.zip',
      '/tmp/Downloads',
    );

    await store.save([first]);
    await store.save([second]);

    expect((await store.load()).map((task) => task.fileName), ['second.zip']);
  });

  test('uses the configured home Downloads directory', () async {
    expect(await store.configuredDownloadDirectory(), isNull);
    expect(
      await store.defaultDownloadDirectory(),
      '${temporaryDirectory.path}${Platform.pathSeparator}home${Platform.pathSeparator}Downloads',
    );
  });

  test(
    'persists a selected download directory across store instances',
    () async {
      const selectedDirectory = '/Users/test/Archive Downloads';
      await store.saveDownloadDirectory(selectedDirectory);

      final restoredStore = DownloadQueueStore(
        supportDirectory: Directory('${temporaryDirectory.path}/support'),
        homeDirectory: Directory('${temporaryDirectory.path}/home'),
      );

      expect(
        await restoredStore.configuredDownloadDirectory(),
        selectedDirectory,
      );
      expect(await restoredStore.defaultDownloadDirectory(), selectedDirectory);
    },
  );

  test('clearing the selected directory restores the Downloads default', () async {
    await store.saveDownloadDirectory('/tmp/Custom folder');
    await store.saveDownloadDirectory(null);

    expect(await store.configuredDownloadDirectory(), isNull);
    expect(
      await store.defaultDownloadDirectory(),
      '${temporaryDirectory.path}${Platform.pathSeparator}home${Platform.pathSeparator}Downloads',
    );
  });

  test('falls back to Downloads when saved settings are malformed', () async {
    final queueFile = await store.browserBridgeTokenFile();
    final settingsFile = File(
      '${queueFile.parent.path}${Platform.pathSeparator}settings.json',
    );
    await settingsFile.parent.create(recursive: true);
    await settingsFile.writeAsString('{not valid json');

    expect(await store.configuredDownloadDirectory(), isNull);
    expect(
      await store.defaultDownloadDirectory(),
      '${temporaryDirectory.path}${Platform.pathSeparator}home${Platform.pathSeparator}Downloads',
    );
  });

  test(
    'changing the directory does not alter the saved download queue',
    () async {
      final task = DownloadTask.fromUrl(
        'https://example.com/file.zip',
        '/tmp/Downloads',
      );
      await store.save([task]);

      await store.saveDownloadDirectory('/tmp/Custom folder');

      expect((await store.load()).single.id, task.id);
      expect(await store.defaultDownloadDirectory(), '/tmp/Custom folder');
    },
  );

  test('stores the browser bridge token beside the persisted queue', () async {
    final tokenFile = await store.browserBridgeTokenFile();

    expect(
      tokenFile.path,
      '${temporaryDirectory.path}${Platform.pathSeparator}support${Platform.pathSeparator}InternetDownloadManager${Platform.pathSeparator}browser_bridge.token',
    );
  });

  test('reports malformed persisted JSON instead of returning partial data', () async {
    final queueFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}support${Platform.pathSeparator}InternetDownloadManager${Platform.pathSeparator}downloads.json',
    );
    await queueFile.parent.create(recursive: true);
    await queueFile.writeAsString('{not valid json');

    await expectLater(store.load(), throwsA(isA<FormatException>()));
  });

  test('reports a filesystem error when the storage path is blocked', () async {
    final blockingFile = File('${temporaryDirectory.path}/not-a-directory');
    await blockingFile.writeAsString('block');
    final blockedStore = DownloadQueueStore(
      supportDirectory: Directory(blockingFile.path),
    );

    await expectLater(
      blockedStore.save([]),
      throwsA(isA<FileSystemException>()),
    );
  });
}
