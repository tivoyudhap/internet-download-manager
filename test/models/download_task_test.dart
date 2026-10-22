import 'package:flutter_test/flutter_test.dart';
import 'package:internet_download_manager/models/download_task.dart';

void main() {
  group('DownloadTask', () {
    test('creates a queued task using the URL file name', () {
      final task = DownloadTask.fromUrl(
        'https://example.com/releases/app.zip?token=abc',
        '/Users/test/Downloads',
      );

      expect(task.url, 'https://example.com/releases/app.zip?token=abc');
      expect(task.fileName, 'app.zip');
      expect(task.destinationDirectory, '/Users/test/Downloads');
      expect(task.status, DownloadStatus.queued);
      expect(task.receivedBytes, 0);
      expect(task.totalBytes, isNull);
    });

    test('uses a safe fallback name when the URL has no file path', () {
      final task = DownloadTask.fromUrl(
        'https://example.com/',
        '/tmp/Downloads',
      );

      expect(task.fileName, 'download');
    });

    test('creates a stream task with a sanitized Matroska file name', () {
      final task = DownloadTask.fromUrl(
        'https://cdn.example.com/manifest.m3u8?token=secret',
        '/tmp/Downloads',
        isStream: true,
        suggestedFileName: '../my:video.mp4',
        requestHeaders: const {'referer': 'https://site.example/watch'},
      );

      expect(task.fileName, '.._my_video.mkv');
      expect(task.isStream, isTrue);
      expect(task.requestHeaders, {'referer': 'https://site.example/watch'});
    });

    test('decodes and sanitizes the URL path into a safe file name', () {
      final task = DownloadTask.fromUrl(
        'https://example.com/files/my%20installer%20%231.zip',
        '/tmp/Downloads',
      );

      expect(task.fileName, 'my installer #1.zip');
    });

    test('rejects malformed or unsupported URLs', () {
      expect(
        () => DownloadTask.fromUrl('https://', '/tmp/Downloads'),
        throwsFormatException,
      );
      expect(
        () => DownloadTask.fromUrl(
          'ftp://example.com/file.zip',
          '/tmp/Downloads',
        ),
        throwsFormatException,
      );
      expect(
        () => DownloadTask.fromUrl('not a URL', '/tmp/Downloads'),
        throwsFormatException,
      );
    });

    test('round trips through JSON with optional metadata', () {
      final task = DownloadTask(
        id: 'task-1',
        url: 'https://example.com/archive.zip',
        fileName: 'archive.zip',
        destinationDirectory: '/tmp/Downloads',
        status: DownloadStatus.paused,
        createdAt: DateTime.utc(2026, 10, 22, 10),
        totalBytes: 1024,
        receivedBytes: 512,
        speedBytesPerSecond: 128.5,
        errorMessage: 'Connection interrupted',
      );

      final restored = DownloadTask.fromJson(task.toJson());

      expect(restored.id, task.id);
      expect(restored.url, task.url);
      expect(restored.fileName, task.fileName);
      expect(restored.destinationDirectory, task.destinationDirectory);
      expect(restored.status, task.status);
      expect(restored.createdAt, task.createdAt);
      expect(restored.totalBytes, task.totalBytes);
      expect(restored.receivedBytes, task.receivedBytes);
      expect(restored.speedBytesPerSecond, task.speedBytesPerSecond);
      expect(restored.errorMessage, task.errorMessage);
      expect(restored.requestHeaders, isEmpty);
    });

    test('does not persist session request headers in the saved queue', () {
      final task = DownloadTask.fromUrl(
        'https://cdn.example.com/video.mpd',
        '/tmp/Downloads',
        isStream: true,
        requestHeaders: const {'cookie': 'session=private'},
      );

      expect(task.toJson().containsKey('requestHeaders'), isFalse);
      expect(DownloadTask.fromJson(task.toJson()).requestHeaders, isEmpty);
    });
  });
}
