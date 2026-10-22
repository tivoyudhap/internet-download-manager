import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internet_download_manager/main.dart';
import 'package:internet_download_manager/models/download_task.dart';
import 'package:internet_download_manager/services/download_queue_controller.dart';
import 'package:internet_download_manager/services/download_engine.dart';
import 'package:internet_download_manager/services/download_queue_store.dart';

class _ImmediateDownloadEngine implements DownloadEngine {
  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
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
  }) {
    onProgress(receivedBytes: 512, totalBytes: 1024, bytesPerSecond: 256);
    return result.future;
  }
}

class _FailingDownloadEngine implements DownloadEngine {
  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
  }) async {
    onProgress(receivedBytes: 128, totalBytes: 1024, bytesPerSecond: 64);
    throw const DownloadException('Network error: connection refused');
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

void main() {
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
}
