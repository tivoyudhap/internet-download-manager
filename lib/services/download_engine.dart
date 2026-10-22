import 'dart:async';
import 'dart:convert';
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
  void Function()? _pauseHandler;

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

  void registerPauseHandler(void Function() handler) {
    _pauseHandler = handler;
    if (_isPaused) handler();
  }

  void pause() {
    if (_isCanceled || _isPaused) return;
    _isPaused = true;
    _resumeCompleter = Completer<void>();
    _pauseHandler?.call();
  }

  void resume() {
    if (_isCanceled || !_isPaused) return;
    _isPaused = false;
    _resumeCompleter?.complete();
    _resumeCompleter = null;
  }

  void cancel() {
    if (_isCanceled) return;
    _isCanceled = true;
    _canceledCompleter.complete();
    _isPaused = false;
    _resumeCompleter?.complete();
    _resumeCompleter = null;
    _cancelHandler?.call();
    _cancelHandler = null;
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
  HttpDownloadEngine({
    HttpClient Function()? clientFactory,
    this.segmentCount = 4,
    this.minimumSegmentedSize = 1024 * 1024,
  }) : _clientFactory = clientFactory ?? HttpClient.new {
    if (segmentCount < 2) {
      throw ArgumentError.value(segmentCount, 'segmentCount');
    }
  }

  final HttpClient Function() _clientFactory;
  final int segmentCount;
  final int minimumSegmentedSize;

  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
    DownloadControl? control,
  }) async {
    final uri = Uri.parse(task.url);
    if (task.isStream) {
      return FfmpegStreamDownloadEngine().download(
        task,
        onProgress: onProgress,
        control: control,
      );
    }
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
    var existingBytes = 0;
    if (await partialFile.exists()) existingBytes = await partialFile.length();
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 30)
      ..userAgent = 'InternetDownloadManager/1.0';
    control?.registerCancelHandler(() => client.close(force: true));
    IOSink? sink;
    StreamIterator<List<int>>? responseIterator;

    try {
      final request = await _withCancellation(client.getUrl(uri), control);
      _setRequestHeaders(request, task.requestHeaders);
      if (existingBytes > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
      } else {
        // A one-byte range acts as a capability probe and can be reused as
        // the first segment when the server supports byte ranges.
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      }
      control?.registerCancelHandler(() => request.abort());
      var response = await _withCancellation(request.close(), control);

      if (existingBytes == 0 &&
          response.statusCode == HttpStatus.partialContent) {
        final probeRange = _parseContentRange(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        final probeBytes = await response.fold<int>(
          0,
          (count, chunk) => count + chunk.length,
        );
        if (probeRange != null &&
            probeRange.start == 0 &&
            probeRange.end == 0 &&
            probeRange.total != null &&
            probeRange.total! >= minimumSegmentedSize &&
            probeRange.total! >= 2 &&
            probeBytes == 1) {
          return await _downloadSegments(
            client: client,
            uri: uri,
            destination: destination,
            partialFile: partialFile,
            totalBytes: probeRange.total!,
            validator: _rangeValidator(response),
            requestHeaders: task.requestHeaders,
            onProgress: onProgress,
            control: control,
          );
        }
        // Small or malformed probe response: fetch the complete object using
        // the existing single-stream path.
        final restartedRequest = await _withCancellation(
          client.getUrl(uri),
          control,
        );
        _setRequestHeaders(restartedRequest, task.requestHeaders);
        control?.registerCancelHandler(() => restartedRequest.abort());
        response = await _withCancellation(restartedRequest.close(), control);
      }

      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          existingBytes > 0) {
        final completeLength = _unsatisfiedRangeLength(response);
        await response.drain<void>();
        if (completeLength == existingBytes) {
          await partialFile.rename(destination.path);
          onProgress(
            receivedBytes: existingBytes,
            totalBytes: existingBytes,
            bytesPerSecond: 0,
          );
          return DownloadResult(
            fileName: destination.path.split(Platform.pathSeparator).last,
            totalBytes: existingBytes,
          );
        }
      }

      final isPartialResponse =
          response.statusCode == HttpStatus.partialContent;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw DownloadException('Server returned HTTP ${response.statusCode}.');
      }
      final contentRange = isPartialResponse
          ? _parseContentRange(
              response.headers.value(HttpHeaders.contentRangeHeader),
            )
          : null;
      final responseLength = response.contentLength >= 0
          ? response.contentLength
          : null;
      if (isPartialResponse &&
          (contentRange == null ||
              contentRange.start != existingBytes ||
              (responseLength != null &&
                  contentRange.end - contentRange.start + 1 !=
                      responseLength))) {
        await response.drain<void>();
        throw const DownloadException('Server returned an invalid byte range.');
      }
      final startOffset = isPartialResponse ? existingBytes : 0;
      final totalBytes =
          contentRange?.total ??
          (responseLength == null ? null : startOffset + responseLength);
      sink = partialFile.openWrite(
        mode: isPartialResponse ? FileMode.append : FileMode.writeOnly,
      );
      responseIterator = StreamIterator<List<int>>(response);
      control?.registerCancelHandler(
        () => unawaited(responseIterator?.cancel()),
      );
      final stopwatch = Stopwatch()..start();
      var receivedResponseBytes = 0;
      var lastReportedAt = Duration.zero;

      while (await _withCancellation(responseIterator.moveNext(), control)) {
        await control?.waitUntilResumed();
        final chunk = responseIterator.current;
        sink.add(chunk);
        receivedResponseBytes += chunk.length;
        final receivedBytes = startOffset + receivedResponseBytes;
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

      if (responseLength != null && receivedResponseBytes != responseLength) {
        throw DownloadException(
          'Download ended early ($receivedResponseBytes of $responseLength bytes received).',
        );
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final receivedBytes = startOffset + receivedResponseBytes;
      if (totalBytes != null && receivedBytes != totalBytes) {
        throw DownloadException(
          'Download ended early ($receivedBytes of $totalBytes bytes received).',
        );
      }
      await partialFile.rename(destination.path);
      stopwatch.stop();
      final finalSize = receivedBytes;
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

  Future<DownloadResult> _downloadSegments({
    required HttpClient client,
    required Uri uri,
    required File destination,
    required File partialFile,
    required int totalBytes,
    required _RangeValidator? validator,
    required Map<String, String> requestHeaders,
    required DownloadProgressCallback onProgress,
    required DownloadControl? control,
  }) async {
    final count = segmentCount.clamp(2, totalBytes);
    final segments = <_DownloadSegment>[];
    for (var index = 0; index < count; index++) {
      final start = totalBytes * index ~/ count;
      final end = totalBytes * (index + 1) ~/ count - 1;
      segments.add(
        _DownloadSegment(
          start: start,
          end: end,
          file: File('${partialFile.path}.seg$index'),
        ),
      );
    }

    final metadataFile = File('${partialFile.path}.meta');
    final canReuseSegments = await _matchesStoredValidator(
      metadataFile,
      totalBytes: totalBytes,
      validator: validator,
    );
    if (!canReuseSegments) {
      for (final segment in segments) {
        if (await segment.file.exists()) await segment.file.delete();
      }
      if (await partialFile.exists()) await partialFile.delete();
      if (await metadataFile.exists()) await metadataFile.delete();
    }
    if (validator != null) {
      await metadataFile.writeAsString(
        '$totalBytes\n${validator.headerName}\n${validator.value}',
        flush: true,
      );
    }

    var receivedBytes = 0;
    for (final segment in segments) {
      if (!await segment.file.exists()) continue;
      final size = await segment.file.length();
      if (size > segment.length) {
        await segment.file.delete();
      } else {
        receivedBytes += size;
      }
    }
    final stopwatch = Stopwatch()..start();
    try {
      await Future.wait(
        segments.map((segment) async {
          var offset = segment.start;
          if (await segment.file.exists()) {
            offset += await segment.file.length();
          }
          if (offset > segment.end) return;

          final request = await _withCancellation(client.getUrl(uri), control);
          _setRequestHeaders(request, requestHeaders);
          request.headers.set(
            HttpHeaders.rangeHeader,
            'bytes=$offset-${segment.end}',
          );
          if (validator != null) {
            request.headers.set('if-range', validator.value);
          }
          control?.registerCancelHandler(() => request.abort());
          final response = await _withCancellation(request.close(), control);
          final range = _parseContentRange(
            response.headers.value(HttpHeaders.contentRangeHeader),
          );
          final responseValidator = validator == null
              ? null
              : response.headers.value(validator.headerName);
          if (response.statusCode == HttpStatus.ok ||
              (validator != null &&
                  responseValidator != null &&
                  responseValidator != validator.value)) {
            await response.drain<void>();
            throw const _RemoteSourceChangedException();
          }
          if (response.statusCode != HttpStatus.partialContent ||
              range == null ||
              range.start != offset ||
              range.end != segment.end ||
              range.total != totalBytes) {
            await response.drain<void>();
            throw const DownloadException(
              'Server returned an invalid byte range for a segment.',
            );
          }

          final sink = segment.file.openWrite(
            mode: offset == segment.start
                ? FileMode.writeOnly
                : FileMode.append,
          );
          var segmentBytes = offset - segment.start;
          final iterator = StreamIterator<List<int>>(response);
          control?.registerCancelHandler(() => unawaited(iterator.cancel()));
          try {
            while (await _withCancellation(iterator.moveNext(), control)) {
              await control?.waitUntilResumed();
              final chunk = iterator.current;
              sink.add(chunk);
              segmentBytes += chunk.length;
              receivedBytes += chunk.length;
              final elapsed = stopwatch.elapsed;
              onProgress(
                receivedBytes: receivedBytes,
                totalBytes: totalBytes,
                bytesPerSecond: elapsed.inMicroseconds == 0
                    ? 0
                    : receivedBytes * 1000000 / elapsed.inMicroseconds,
              );
            }
          } finally {
            await sink.close();
          }
          if (segmentBytes != segment.length) {
            throw const DownloadException('A download segment ended early.');
          }
        }),
      );
    } on _RemoteSourceChangedException {
      for (final segment in segments) {
        if (await segment.file.exists()) await segment.file.delete();
      }
      if (await partialFile.exists()) await partialFile.delete();
      if (await metadataFile.exists()) await metadataFile.delete();
      throw const DownloadException(
        'The remote file changed during the segmented download. Retry to start over.',
      );
    }

    await control?.waitUntilResumed();
    final output = partialFile.openWrite(mode: FileMode.writeOnly);
    try {
      for (final segment in segments) {
        await output.addStream(segment.file.openRead());
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (await partialFile.length() != totalBytes) {
      throw const DownloadException('Combined download has an invalid size.');
    }
    await partialFile.rename(destination.path);
    for (final segment in segments) {
      if (await segment.file.exists()) await segment.file.delete();
    }
    if (await metadataFile.exists()) await metadataFile.delete();
    final elapsed = stopwatch.elapsed;
    onProgress(
      receivedBytes: totalBytes,
      totalBytes: totalBytes,
      bytesPerSecond: elapsed.inMicroseconds == 0
          ? 0
          : totalBytes * 1000000 / elapsed.inMicroseconds,
    );
    return DownloadResult(
      fileName: destination.path.split(Platform.pathSeparator).last,
      totalBytes: totalBytes,
    );
  }

  Future<bool> _matchesStoredValidator(
    File metadataFile, {
    required int totalBytes,
    required _RangeValidator? validator,
  }) async {
    if (validator == null || !await metadataFile.exists()) return false;
    try {
      final lines = await metadataFile.readAsLines();
      return lines.length == 3 &&
          lines[0] == '$totalBytes' &&
          lines[1] == validator.headerName &&
          lines[2] == validator.value;
    } on FileSystemException {
      return false;
    }
  }

  _RangeValidator? _rangeValidator(HttpClientResponse response) {
    final etag = response.headers.value(HttpHeaders.etagHeader);
    if (etag != null && !etag.toLowerCase().startsWith('w/')) {
      return _RangeValidator(headerName: HttpHeaders.etagHeader, value: etag);
    }
    final modified = response.headers.value(HttpHeaders.lastModifiedHeader);
    if (modified != null) {
      return _RangeValidator(
        headerName: HttpHeaders.lastModifiedHeader,
        value: modified,
      );
    }
    return null;
  }

  _ContentRange? _parseContentRange(String? value) {
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$')
        .firstMatch(value ?? '');
    if (match == null) return null;
    return _ContentRange(
      start: int.parse(match.group(1)!),
      end: int.parse(match.group(2)!),
      total: int.tryParse(match.group(3)!),
    );
  }

  int? _unsatisfiedRangeLength(HttpClientResponse response) {
    final match = RegExp(
      r'^bytes \*/(\d+)$',
    ).firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
    return match == null ? null : int.tryParse(match.group(1)!);
  }

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

  void _setRequestHeaders(
    HttpClientRequest request,
    Map<String, String> headers,
  ) {
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
  }
}

class FfmpegStreamDownloadEngine implements DownloadEngine {
  FfmpegStreamDownloadEngine({
    String? executable,
    Future<Process> Function(String, List<String>)? processFactory,
  }) : executable =
           executable ?? Platform.environment['IDM_FFMPEG_PATH'] ?? 'ffmpeg',
       _processFactory = processFactory ?? Process.start;

  final String executable;
  final Future<Process> Function(String, List<String>) _processFactory;

  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    required DownloadProgressCallback onProgress,
    DownloadControl? control,
  }) async {
    final directory = Directory(task.destinationDirectory);
    try {
      await directory.create(recursive: true);
    } on FileSystemException catch (error) {
      throw DownloadException('File error: ${error.message}');
    }
    final destination = await _availableDestination(directory, task.fileName);
    final partial = File('${destination.path}.${task.id}.part.mkv');

    while (true) {
      await control?.waitUntilResumed();
      if (control?.isCanceled ?? false) throw const DownloadCanceledException();
      if (await partial.exists()) await partial.delete();

      final arguments = <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-y',
      ];
      final inputHeaders = Map<String, String>.of(task.requestHeaders);
      final cookie = inputHeaders.remove('cookie');
      if (cookie != null && cookie.isNotEmpty) {
        final host = Uri.parse(task.url).host;
        final scopedCookies = cookie
            .split(';')
            .map((part) => part.trim())
            .where((part) => part.contains('='))
            .map((part) => '$part; Domain=$host; Path=/')
            .join('\n');
        if (scopedCookies.isNotEmpty) {
          arguments.addAll(['-cookies', scopedCookies]);
        }
      }
      if (inputHeaders.isNotEmpty) {
        final headers = inputHeaders.entries
            .map((entry) => '${entry.key}: ${entry.value}\r\n')
            .join();
        arguments.addAll(['-headers', headers]);
      }
      arguments.addAll([
        '-i',
        task.url,
        '-map',
        '0:v:0?',
        '-map',
        '0:a:0?',
        '-c',
        'copy',
        '-progress',
        'pipe:1',
        '-nostats',
        partial.path,
      ]);

      final Process process;
      try {
        process = await _processFactory(await _resolveExecutable(), arguments);
      } on ProcessException catch (error) {
        throw DownloadException(
          'FFmpeg is required to download video streams: ${error.message}',
        );
      }
      control?.registerCancelHandler(() => process.kill());
      control?.registerPauseHandler(() => process.kill());

      final stopwatch = Stopwatch()..start();
      var receivedBytes = 0;
      final progressTimer = Timer.periodic(const Duration(milliseconds: 300), (
        _,
      ) async {
        if (!await partial.exists()) return;
        final size = await partial.length();
        if (size == receivedBytes) return;
        receivedBytes = size;
        onProgress(
          receivedBytes: size,
          totalBytes: null,
          bytesPerSecond: stopwatch.elapsedMicroseconds == 0
              ? 0
              : size * 1000000 / stopwatch.elapsedMicroseconds,
        );
      });
      unawaited(process.stdout.drain<void>());
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode;
      progressTimer.cancel();
      final stderr = await stderrFuture;
      control?.registerPauseHandler(() {});

      if (control?.isCanceled ?? false) {
        if (await partial.exists()) await partial.delete();
        throw const DownloadCanceledException();
      }
      if (control?.isPaused ?? false) continue;
      if (exitCode != 0) {
        if (await partial.exists()) await partial.delete();
        throw DownloadException(
          stderr.trim().isEmpty
              ? 'FFmpeg could not download this video stream.'
              : stderr.trim(),
        );
      }
      if (!await partial.exists() || await partial.length() == 0) {
        throw const DownloadException('FFmpeg returned an empty video file.');
      }
      final size = await partial.length();
      await partial.rename(destination.path);
      onProgress(
        receivedBytes: size,
        totalBytes: size,
        bytesPerSecond: stopwatch.elapsedMicroseconds == 0
            ? 0
            : size * 1000000 / stopwatch.elapsedMicroseconds,
      );
      return DownloadResult(
        fileName: destination.path.split(Platform.pathSeparator).last,
        totalBytes: size,
      );
    }
  }

  Future<String> _resolveExecutable() async {
    if (executable.contains(Platform.pathSeparator)) return executable;
    if (Platform.isMacOS) {
      for (final candidate in [
        '/opt/homebrew/bin/$executable',
        '/usr/local/bin/$executable',
      ]) {
        final file = File(candidate);
        if (await file.exists()) return candidate;
      }
    }
    return executable;
  }

  Future<File> _availableDestination(
    Directory directory,
    String requestedName,
  ) async {
    var candidate = File(
      '${directory.path}${Platform.pathSeparator}$requestedName',
    );
    if (!await candidate.exists()) return candidate;
    final dot = requestedName.lastIndexOf('.');
    final stem = dot > 0 ? requestedName.substring(0, dot) : requestedName;
    final extension = dot > 0 ? requestedName.substring(dot) : '';
    for (var suffix = 1; ; suffix++) {
      candidate = File(
        '${directory.path}${Platform.pathSeparator}$stem ($suffix)$extension',
      );
      if (!await candidate.exists()) return candidate;
    }
  }
}

class _ContentRange {
  const _ContentRange({required this.start, required this.end, this.total});

  final int start;
  final int end;
  final int? total;
}

class _DownloadSegment {
  const _DownloadSegment({
    required this.start,
    required this.end,
    required this.file,
  });

  final int start;
  final int end;
  final File file;
  int get length => end - start + 1;
}

class _RangeValidator {
  const _RangeValidator({required this.headerName, required this.value});

  final String headerName;
  final String value;
}

class _RemoteSourceChangedException implements Exception {
  const _RemoteSourceChangedException();
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
