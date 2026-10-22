import 'dart:async';
import 'dart:io';

import '../models/download_task.dart';

typedef DownloadProgressCallback = void Function({
  required int receivedBytes,
  required int? totalBytes,
  required double bytesPerSecond,
});

class DownloadControl {
  bool _isPaused = false;
  bool _isCanceled = false;
  Completer<void>? _resumeCompleter;
  final Completer<void> _canceledCompleter = Completer<void>();
  void Function()? _cancelHandler;

  bool get isPaused => _isPaused;
  bool get isCanceled => _isCanceled;
  Future<void> get whenCanceled => _canceledCompleter.future;

  void registerCancelHandler(void Function() handler) {
    if (_isCanceled) {
      handler();
    } else {
      final previousHandler = _cancelHandler;
      _cancelHandler = previousHandler == null
          ? handler
          : () {
              previousHandler();
              handler();
            };
    }
  }

  void pause() {
    if (_isCanceled || _isPaused) return;
    _isPaused = true;
    _resumeCompleter = Completer<void>();
  }

  void resume() {
    if (_isCanceled || !_isPaused) return;
    _isPaused = false;
    _resumeCompleter?.complete();
    _resumeCompleter = null;
    _cancelHandler?.call();
    _cancelHandler = null;
  }

  void cancel() {
    if (_isCanceled) return;
    _isCanceled = true;
    _canceledCompleter.complete();
    _isPaused = false;
    _resumeCompleter?.complete();
    _resumeCompleter = null;
  }

  Future<void> waitUntilResumed() async {
    if (_isPaused) await _resumeCompleter?.future;
    if (_isCanceled) throw const DownloadCanceledException();
  }
}

class DownloadResult {
  const DownloadResult({required this.fileName, required this.totalBytes});

  final String fileName;
  final int totalBytes;
}

abstract interface class DownloadEngine {
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
    DownloadControl? control,
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
    DownloadControl? control,
  }) async {
    final uri = Uri.parse(task.url);
    final destinationDirectory = Directory(task.destinationDirectory);
    try {
      await destinationDirectory.create(recursive: true);
    } on FileSystemException catch (error) {
      throw DownloadException('File error: ${error.message}');
    }
    final destination = await _availableDestination(
      destinationDirectory,
      task.fileName,
    );
    final partialFile = File('${destination.path}.${task.id}.part');
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 30)
      ..userAgent = 'InternetDownloadManager/1.0';
    control?.registerCancelHandler(() => client.close(force: true));
    IOSink? sink;
    StreamIterator<List<int>>? responseIterator;

    try {
      final request = await _withCancellation(client.getUrl(uri), control);
      control?.registerCancelHandler(() => request.abort());
      final response = await _withCancellation(request.close(), control);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw DownloadException('Server returned HTTP ${response.statusCode}.');
      }

      final totalBytes = response.contentLength >= 0
          ? response.contentLength
          : null;
      sink = partialFile.openWrite(mode: FileMode.writeOnly);
      responseIterator = StreamIterator<List<int>>(response);
      control?.registerCancelHandler(
        () => unawaited(responseIterator?.cancel()),
      );
      final stopwatch = Stopwatch()..start();
      var receivedBytes = 0;
      var lastReportedAt = Duration.zero;

      while (await _withCancellation(responseIterator.moveNext(), control)) {
        await control?.waitUntilResumed();
        final chunk = responseIterator.current;
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

      await control?.waitUntilResumed();

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
      if (control?.isCanceled ?? false) {
        throw const DownloadCanceledException();
      }
      throw DownloadException('Network error: ${error.message}');
    } on HttpException catch (error) {
      if (control?.isCanceled ?? false) {
        throw const DownloadCanceledException();
      }
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

  Future<T> _withCancellation<T>(Future<T> future, DownloadControl? control) {
    if (control == null) return future;
    if (control.isCanceled) {
      return Future<T>.error(const DownloadCanceledException());
    }
    final canceled = control.whenCanceled.then<T>(
      (_) => throw const DownloadCanceledException(),
    );
    return Future.any<T>([future, canceled]);
  }
}

class DownloadException implements Exception {
  const DownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DownloadCanceledException implements Exception {
  const DownloadCanceledException();

  @override
  String toString() => 'Download canceled.';
}
