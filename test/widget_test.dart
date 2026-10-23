import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internet_download_manager/main.dart';
import 'package:internet_download_manager/models/download_task.dart';
import 'package:internet_download_manager/services/download_queue_controller.dart';
import 'package:internet_download_manager/services/download_engine.dart';
import 'package:internet_download_manager/services/download_directory_picker.dart';
import 'package:internet_download_manager/services/download_queue_store.dart';

class _ImmediateDownloadEngine implements DownloadEngine {
  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
    DownloadControl? control,
  }) async {
    onProgress(receivedBytes: 1024, totalBytes: 1024, bytesPerSecond: 512);
    return DownloadResult(fileName: task.fileName, totalBytes: 1024);
  }
}

class _ControlledDownloadEngine implements DownloadEngine {
  final result = Completer<DownloadResult>();

  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
    DownloadControl? control,
  }) async {
    onProgress(receivedBytes: 512, totalBytes: 1024, bytesPerSecond: 256);
    final downloadResult = await result.future;
    await control?.waitUntilResumed();
    return downloadResult;
  }
}

class _FailingDownloadEngine implements DownloadEngine {
  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
    DownloadControl? control,
  }) async {
    onProgress(receivedBytes: 128, totalBytes: 1024, bytesPerSecond: 64);
    throw const DownloadException('Network error: connection refused');
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
    return DownloadResult(fileName: task.fileName, totalBytes: 1024);
  }
}

class _MemoryQueueStore extends DownloadQueueStore {
  List<DownloadTask> savedTasks = [];

  @override
  Future<List<DownloadTask>> load() async => List.of(savedTasks);

  @override
  Future<void> save(List<DownloadTask> tasks) async {
    savedTasks = List.of(tasks);
  }

  @override
  Future<String> defaultDownloadDirectory() async => '/test/Downloads';
}

class _MemorySettingsStore extends DownloadQueueStore {
  _MemorySettingsStore();

  final String homeDirectoryPath = '/test-home';
  String? selectedDirectory;

  @override
  Future<String?> configuredDownloadDirectory() async => selectedDirectory;

  @override
  Future<String> defaultDownloadDirectory() async =>
      selectedDirectory ?? '$homeDirectoryPath/Downloads';

  @override
  Future<void> saveDownloadDirectory(String? directory) async {
    selectedDirectory = directory;
  }
}

class _DelayedLoadQueueStore extends _MemoryQueueStore {
  final loadResult = Completer<List<DownloadTask>>();

  @override
  Future<List<DownloadTask>> load() => loadResult.future;
}

class _FailingLoadQueueStore extends _MemoryQueueStore {
  @override
  Future<List<DownloadTask>> load() async =>
      throw const FormatException('Saved queue is not valid JSON.');
}

class _FakeDownloadDirectoryPicker extends DownloadDirectoryPicker {
  _FakeDownloadDirectoryPicker({this.selectedDirectory, this.pickError});

  final String? selectedDirectory;
  final Object? pickError;
  final calls = <String>[];

  @override
  Future<String?> pickDirectory() async {
    calls.add('pickDirectory');
    if (pickError case final error?) throw error;
    return selectedDirectory;
  }

  @override
  Future<void> clearAccess() async {
    calls.add('clearAccess');
  }
}

void main() {
  testWidgets('shows loading and empty states during queue restoration', (
    WidgetTester tester,
  ) async {
    final store = _DelayedLoadQueueStore();
    final controller = DownloadQueueController(store);
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));

    expect(find.text('Loading your downloads…'), findsOneWidget);
    expect(find.text('Your download list is empty'), findsNothing);

    store.loadResult.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('Your download list is empty'), findsOneWidget);
    expect(find.text('Add your first download'), findsOneWidget);
  });

  testWidgets('shows the saved queue load error without an empty-state CTA', (
    WidgetTester tester,
  ) async {
    final controller = DownloadQueueController(_FailingLoadQueueStore());
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));
    await tester.pumpAndSettle();

    expect(find.text('Could not load saved downloads'), findsOneWidget);
    expect(
      find.text('FormatException: Saved queue is not valid JSON.'),
      findsOneWidget,
    );
    expect(find.text('Add your first download'), findsNothing);
  });

  testWidgets('adds a validated URL to the visible queue', (
    WidgetTester tester,
  ) async {
    final store = _MemoryQueueStore();
    final controller = DownloadQueueController(
      store,
      engine: _ImmediateDownloadEngine(),
    );
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));
    await tester.pumpAndSettle();

    expect(find.text('Your download list is empty'), findsOneWidget);
    await tester.tap(find.text('Add URL'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).last,
      'https://example.com/files/installer.zip',
    );
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();

    expect(find.text('installer.zip'), findsOneWidget);
    expect(find.text('Completed'), findsNWidgets(2));
    expect(store.savedTasks, hasLength(1));
    expect(
      store.savedTasks.single.url,
      'https://example.com/files/installer.zip',
    );
  });

  testWidgets('rejects non-HTTP URLs', (WidgetTester tester) async {
    final controller = DownloadQueueController(_MemoryQueueStore());
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add URL'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'file:///etc/passwd');
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid HTTP or HTTPS URL.'), findsOneWidget);
    expect(find.text('Add new download'), findsOneWidget);
  });

  testWidgets('shows live progress, speed, and ETA while downloading', (
    WidgetTester tester,
  ) async {
    final engine = _ControlledDownloadEngine();
    final controller = DownloadQueueController(
      _MemoryQueueStore(),
      engine: engine,
    );
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add URL'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'https://example.com/large.iso',
    );
    await tester.tap(find.text('Add to queue'));
    await tester.pump();
    await tester.pump();

    expect(find.text('large.iso'), findsOneWidget);
    expect(find.text('Downloading'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('256 B/s · 2 sec left'), findsOneWidget);
    expect(find.text('512 B / 1.0 KB'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('Download actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    expect(find.text('Paused'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('Download actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    expect(find.text('Downloading'), findsOneWidget);

    engine.result.complete(
      const DownloadResult(fileName: 'large.iso', totalBytes: 1024),
    );
    await tester.pumpAndSettle();
    expect(find.text('Completed'), findsNWidgets(2));
  });

  testWidgets('shows the download error and received bytes on failure', (
    WidgetTester tester,
  ) async {
    final controller = DownloadQueueController(
      _MemoryQueueStore(),
      engine: _FailingDownloadEngine(),
    );
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add URL'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'https://example.com/unavailable.zip',
    );
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();

    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Network error: connection refused'), findsOneWidget);
    expect(find.text('128 B / 1.0 KB'), findsOneWidget);
  });

  testWidgets('cancels a queued download from its row actions', (
    WidgetTester tester,
  ) async {
    final store = _MemoryQueueStore()
      ..savedTasks = [
        DownloadTask(
          id: 'queued-cancel',
          url: 'https://example.com/queued.zip',
          fileName: 'queued.zip',
          destinationDirectory: '/test/Downloads',
          status: DownloadStatus.queued,
          createdAt: DateTime.utc(2026, 10, 22),
        ),
      ];
    final controller = DownloadQueueController(store);
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip('Download actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Canceled'), findsOneWidget);
    expect(store.savedTasks.single.status, DownloadStatus.canceled);
  });

  testWidgets('retries a failed download from its row actions', (
    WidgetTester tester,
  ) async {
    final engine = _FailOnceDownloadEngine();
    final controller = DownloadQueueController(
      _MemoryQueueStore(),
      engine: engine,
    );
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add URL'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'https://example.com/retry.zip',
    );
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();
    expect(find.text('Failed'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('Download actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(engine.calls, 2);
    expect(find.text('Completed'), findsNWidgets(2));
  });

  testWidgets('category selection and search filter queued items', (
    WidgetTester tester,
  ) async {
    final store = _MemoryQueueStore()
      ..savedTasks = [
        DownloadTask(
          id: 'queued-1',
          url: 'https://example.com/installer.zip',
          fileName: 'installer.zip',
          destinationDirectory: '/test/Downloads',
          status: DownloadStatus.queued,
          createdAt: DateTime.utc(2026, 10, 22),
        ),
        DownloadTask(
          id: 'complete-1',
          url: 'https://example.com/notes.pdf',
          fileName: 'notes.pdf',
          destinationDirectory: '/test/Downloads',
          status: DownloadStatus.completed,
          createdAt: DateTime.utc(2026, 10, 22),
        ),
      ];
    final controller = DownloadQueueController(store);
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));
    await tester.pumpAndSettle();

    expect(find.text('installer.zip'), findsOneWidget);
    expect(find.text('notes.pdf'), findsOneWidget);
    expect(find.text('All downloads'), findsWidgets);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('Active downloads'), findsNothing);
    expect(find.text('Completed today'), findsNothing);
    expect(find.text('Queue remaining'), findsNothing);
    await tester.tap(find.text('Completed').first);
    await tester.pumpAndSettle();
    expect(find.text('notes.pdf'), findsOneWidget);
    expect(find.text('installer.zip'), findsNothing);

    await tester.tap(find.text('All downloads').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'installer');
    await tester.pumpAndSettle();

    expect(find.text('installer.zip'), findsOneWidget);
    expect(find.text('notes.pdf'), findsNothing);
  });

  testWidgets('clears terminal history from the All downloads options', (
    WidgetTester tester,
  ) async {
    DownloadTask task(String id, DownloadStatus status) => DownloadTask(
      id: id,
      url: 'https://example.com/$id.zip',
      fileName: '$id.zip',
      destinationDirectory: '/test/Downloads',
      status: status,
      createdAt: DateTime.utc(2026, 10, 22),
    );
    final store = _MemoryQueueStore()
      ..savedTasks = [
        task('done', DownloadStatus.completed),
        task('broken', DownloadStatus.failed),
        task('stopped', DownloadStatus.canceled),
        task('waiting', DownloadStatus.queued),
      ];
    final controller = DownloadQueueController(store);
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear all history'));
    await tester.pumpAndSettle();
    expect(find.text('Clear all history?'), findsOneWidget);
    expect(find.text('done.zip'), findsOneWidget);

    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(store.savedTasks, hasLength(4));

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear all history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();

    expect(store.savedTasks, hasLength(1));
    expect(store.savedTasks.single.fileName, 'waiting.zip');
    expect(find.text('done.zip'), findsNothing);
    expect(find.text('broken.zip'), findsNothing);
    expect(find.text('stopped.zip'), findsNothing);
    expect(find.text('waiting.zip'), findsOneWidget);
    expect(find.text('Download history cleared.'), findsOneWidget);
  });

  testWidgets('clears history for one completed download from its row menu', (
    WidgetTester tester,
  ) async {
    final completedTask = DownloadTask(
      id: 'completed-one',
      url: 'https://example.com/completed.zip',
      fileName: 'completed.zip',
      destinationDirectory: '/test/Downloads',
      status: DownloadStatus.completed,
      createdAt: DateTime.utc(2026, 10, 22),
    );
    final queuedTask = DownloadTask.fromUrl(
      'https://example.com/waiting.zip',
      '/test/Downloads',
    );
    final store = _MemoryQueueStore()..savedTasks = [completedTask, queuedTask];
    final controller = DownloadQueueController(store);
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip('Download actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Clear history'), findsOneWidget);
    expect(find.text('Delete file'), findsOneWidget);
    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();

    expect(store.savedTasks.map((task) => task.id), [queuedTask.id]);
    expect(find.text('completed.zip'), findsNothing);
    expect(find.text('waiting.zip'), findsOneWidget);
    expect(find.text('Removed from download history.'), findsOneWidget);
  });

  testWidgets('asks before deleting a completed file', (
    WidgetTester tester,
  ) async {
    final completedTask = DownloadTask(
      id: 'completed-one',
      url: 'https://example.com/completed.zip',
      fileName: 'completed.zip',
      destinationDirectory: '/test/Downloads',
      status: DownloadStatus.completed,
      createdAt: DateTime.utc(2026, 10, 22),
    );
    final store = _MemoryQueueStore()..savedTasks = [completedTask];
    final controller = DownloadQueueController(store);
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip('Download actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete file'));
    await tester.pumpAndSettle();

    expect(find.text('Delete downloaded file?'), findsOneWidget);
    expect(
      find.textContaining('Permanently delete "completed.zip"'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(store.savedTasks.single.id, completedTask.id);
  });

  testWidgets('rejects HTTP URLs without a host', (WidgetTester tester) async {
    final controller = DownloadQueueController(_MemoryQueueStore());
    await tester.pumpWidget(DownloadManagerApp(queueController: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add URL'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'https://');
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid HTTP or HTTPS URL.'), findsOneWidget);
    expect(find.text('Add new download'), findsOneWidget);
  });

  testWidgets('selects and resets the download folder from Settings', (
    WidgetTester tester,
  ) async {
    final settingsStore = _MemorySettingsStore();
    final picker = _FakeDownloadDirectoryPicker(
      selectedDirectory: '/tmp/Chosen folder',
    );

    await tester.pumpWidget(
      DownloadManagerApp(
        queueController: DownloadQueueController(_MemoryQueueStore()),
        settingsStore: settingsStore,
        directoryPicker: picker,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Download location'), findsOneWidget);
    expect(find.text('/test-home/Downloads'), findsOneWidget);

    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    expect(find.text('/tmp/Chosen folder'), findsOneWidget);
    expect(
      await settingsStore.defaultDownloadDirectory(),
      '/tmp/Chosen folder',
    );

    await tester.tap(find.text('Use Downloads folder'));
    await tester.pumpAndSettle();
    expect(find.text('/test-home/Downloads'), findsOneWidget);
    expect(await settingsStore.configuredDownloadDirectory(), isNull);
    expect(picker.calls, ['pickDirectory', 'clearAccess']);
  });

  testWidgets('leaves the current folder unchanged when picker is canceled', (
    WidgetTester tester,
  ) async {
    final settingsStore = _MemorySettingsStore()
      ..selectedDirectory = '/tmp/Existing folder';
    final picker = _FakeDownloadDirectoryPicker();

    await tester.pumpWidget(
      DownloadManagerApp(
        queueController: DownloadQueueController(_MemoryQueueStore()),
        settingsStore: settingsStore,
        directoryPicker: picker,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();

    expect(find.text('/tmp/Existing folder'), findsOneWidget);
    expect(
      await settingsStore.defaultDownloadDirectory(),
      '/tmp/Existing folder',
    );
  });

  testWidgets('shows a picker error and remains usable', (
    WidgetTester tester,
  ) async {
    final settingsStore = _MemorySettingsStore();
    final picker = _FakeDownloadDirectoryPicker(
      pickError: PlatformException(
        code: 'PICKER_FAILED',
        message: 'Picker failed',
      ),
    );

    await tester.pumpWidget(
      DownloadManagerApp(
        queueController: DownloadQueueController(_MemoryQueueStore()),
        settingsStore: settingsStore,
        directoryPicker: picker,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();

    expect(find.text('Could not select folder: Picker failed'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    expect(await settingsStore.configuredDownloadDirectory(), isNull);
  });
}
