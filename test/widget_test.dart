import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internet_download_manager/main.dart';
import 'package:internet_download_manager/models/download_task.dart';
import 'package:internet_download_manager/services/download_queue_controller.dart';
import 'package:internet_download_manager/services/download_queue_store.dart';

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
    final controller = DownloadQueueController(store);
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
    expect(find.text('Queued'), findsOneWidget);
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
