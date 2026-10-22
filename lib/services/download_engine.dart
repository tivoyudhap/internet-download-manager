import 'dart:async';
import 'dart:io';

import '../models/download_task.dart';

typedef DownloadProgressCallback = void Function({
  required int receivedBytes,
  required int? totalBytes,
  required double bytesPerSecond,
});

class DownloadResult {
  const DownloadResult({required this.fileName, required this.totalBytes});

  final String fileName;
  final int totalBytes;
}

abstract interface class DownloadEngine {
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
  });
}

class HttpDownloadEngine implements DownloadEngine {
  HttpDownloadEngine({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;

  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
  }) async {
    final uri = Uri.parse(task.url);
    final destinationDirectory = Directory(task.destinationDirectory);
    await destinationDirectory.create(recursive: true);
    final destination = await _availableDestination(
      destinationDirectory,
      task.fileName,
    );
    final partialFile = File('${destination.path}.${task.id}.part');
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 30)
      ..userAgent = 'InternetDownloadManager/1.0';
    IOSink? sink;

    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw DownloadException('Server returned HTTP ${response.statusCode}.');
      }

      final totalBytes = response.contentLength >= 0
          ? response.contentLength
          : null;
      sink = partialFile.openWrite(mode: FileMode.writeOnly);
      final stopwatch = Stopwatch()..start();
      var receivedBytes = 0;
      var lastReportedAt = Duration.zero;

      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        final elapsed = stopwatch.elapsed;
        if (elapsed - lastReportedAt >= const Duration(milliseconds: 200)) {
          onProgress(
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: elapsed.inMicroseconds == 0
                ? 0
                : receivedBytes * 1000000 / elapsed.inMicroseconds,
          );
          lastReportedAt = elapsed;
        }
      }

      if (totalBytes != null && receivedBytes != totalBytes) {
        throw DownloadException(
          'Download ended early ($receivedBytes of $totalBytes bytes received).',
        );
      }
      await sink.flush();
      await sink.close();
      sink = null;
      await partialFile.rename(destination.path);
      stopwatch.stop();
      final finalSize = totalBytes ?? receivedBytes;
      onProgress(
        receivedBytes: finalSize,
        totalBytes: totalBytes ?? finalSize,
        bytesPerSecond: stopwatch.elapsed.inMicroseconds == 0
            ? 0
            : finalSize * 1000000 / stopwatch.elapsed.inMicroseconds,
      );
      return DownloadResult(
        fileName: destination.path.split(Platform.pathSeparator).last,
        totalBytes: finalSize,
      );
    } on DownloadException {
      rethrow;
    } on SocketException catch (error) {
      throw DownloadException('Network error: ${error.message}');
    } on HttpException catch (error) {
      throw DownloadException('HTTP error: ${error.message}');
    } on FileSystemException catch (error) {
      throw DownloadException('File error: ${error.message}');
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // Keep the original download error if closing the partial file fails.
        }
      }
      client.close(force: true);
    }
  }

  Future<File> _availableDestination(
    Directory directory,
    String requestedName,
  ) async {
    var candidate = File(_join(directory.path, requestedName));
    if (!await candidate.exists()) return candidate;

    final dot = requestedName.lastIndexOf('.');
    final hasExtension = dot > 0;
    final stem = hasExtension ? requestedName.substring(0, dot) : requestedName;
    final extension = hasExtension ? requestedName.substring(dot) : '';
    for (var suffix = 1; ; suffix++) {
      candidate = File(_join(directory.path, '$stem ($suffix)$extension'));
      if (!await candidate.exists()) return candidate;
    }
  }

  String _join(String directory, String fileName) =>
      '$directory${Platform.pathSeparator}$fileName';
}

class DownloadException implements Exception {
  const DownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}
