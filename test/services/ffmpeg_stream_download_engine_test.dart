import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:internet_download_manager/models/download_task.dart';
import 'package:internet_download_manager/services/download_engine.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('idm-ffmpeg-test-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  DownloadTask task({String fileName = 'video.mkv'}) => DownloadTask(
    id: 'stream-task',
    url: 'https://cdn.example.com/master.m3u8?signature=abc',
    fileName: fileName,
    destinationDirectory: directory.path,
    status: DownloadStatus.queued,
    createdAt: DateTime.utc(2026),
    isStream: true,
    requestHeaders: const {
      'cookie': 'session=secret',
      'referer': 'https://site.example/watch',
    },
  );

  void onProgress({
    required int receivedBytes,
    required int? totalBytes,
    required double bytesPerSecond,
  }) {}

  test(
    'remuxes streams into MP4 with session headers and stream mapping',
    () async {
      List<String>? receivedArguments;
      final engine = FfmpegStreamDownloadEngine(
        processFactory: (executable, arguments) async {
          receivedArguments = arguments;
          await File(arguments.last).writeAsBytes([1, 2, 3, 4]);
          return _FakeProcess(exitCode: 0);
        },
      );

      final result = await engine.download(task(), onProgress: onProgress);

      expect(result.fileName, 'video.mp4');
      expect(result.totalBytes, 4);
      expect(await File('${directory.path}/video.mp4').readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      expect(
        receivedArguments,
        contains('https://cdn.example.com/master.m3u8?signature=abc'),
      );
      expect(receivedArguments, contains('0:v:0?'));
      expect(receivedArguments, contains('0:a:0?'));
      expect(receivedArguments, containsAll(['-movflags', '+faststart']));
      expect(receivedArguments, containsAll(['-f', 'mp4']));
      expect(receivedArguments!.last, endsWith('.part.mp4'));
      final cookieIndex = receivedArguments!.indexOf('-cookies');
      expect(
        receivedArguments![cookieIndex + 1],
        contains('session=secret; Domain=cdn.example.com; Path=/'),
      );
      final headerIndex = receivedArguments!.indexOf('-headers');
      expect(
        receivedArguments![headerIndex + 1],
        contains('referer: https://site.example/watch\r\n'),
      );
    },
  );

  test(
    'chooses a numbered destination when the requested name exists',
    () async {
      await File('${directory.path}/video.mp4').writeAsBytes([9]);
      final engine = FfmpegStreamDownloadEngine(
        processFactory: (executable, arguments) async {
          await File(arguments.last).writeAsBytes([1, 2]);
          return _FakeProcess(exitCode: 0);
        },
      );

      final result = await engine.download(task(), onProgress: onProgress);

      expect(result.fileName, 'video (1).mp4');
      expect(await File('${directory.path}/video.mp4').readAsBytes(), [9]);
      expect(await File('${directory.path}/video (1).mp4').readAsBytes(), [
        1,
        2,
      ]);
    },
  );

  test('reports missing FFmpeg with an actionable error', () async {
    final engine = FfmpegStreamDownloadEngine(
      processFactory: (executable, arguments) async =>
          throw ProcessException(executable, arguments, 'not installed'),
    );

    await expectLater(
      engine.download(task(), onProgress: onProgress),
      throwsA(
        isA<DownloadException>().having(
          (error) => error.message,
          'message',
          contains('FFmpeg is required'),
        ),
      ),
    );
  });

  test('surfaces FFmpeg errors and removes incomplete output', () async {
    final engine = FfmpegStreamDownloadEngine(
      processFactory: (executable, arguments) async {
        await File(arguments.last).writeAsBytes([1]);
        return _FakeProcess(exitCode: 1, stderrText: 'HTTP error 403');
      },
    );

    await expectLater(
      engine.download(task(), onProgress: onProgress),
      throwsA(
        isA<DownloadException>().having(
          (error) => error.message,
          'message',
          contains('HTTP error 403'),
        ),
      ),
    );
    expect(
      await File('${directory.path}/video.mp4.stream-task.part.mp4').exists(),
      isFalse,
    );
  });

  test('rejects a successful FFmpeg exit with no media output', () async {
    final engine = FfmpegStreamDownloadEngine(
      processFactory: (executable, arguments) async =>
          _FakeProcess(exitCode: 0),
    );

    await expectLater(
      engine.download(task(), onProgress: onProgress),
      throwsA(
        isA<DownloadException>().having(
          (error) => error.message,
          'message',
          contains('empty video file'),
        ),
      ),
    );
  });

  test('cancels the FFmpeg process and removes its partial output', () async {
    final started = Completer<_FakeProcess>();
    final engine = FfmpegStreamDownloadEngine(
      processFactory: (executable, arguments) async {
        await File(arguments.last).writeAsBytes([1]);
        final process = _FakeProcess.pending();
        started.complete(process);
        return process;
      },
    );
    final control = DownloadControl();
    final download = engine.download(
      task(),
      onProgress: onProgress,
      control: control,
    );
    final process = await started.future;
    control.cancel();

    await expectLater(download, throwsA(isA<DownloadCanceledException>()));
    expect(process.wasKilled, isTrue);
    expect(
      await File('${directory.path}/video.mp4.stream-task.part.mp4').exists(),
      isFalse,
    );
  });

  test(
    'pause stops FFmpeg and resume restarts the stream from its manifest',
    () async {
      final firstStarted = Completer<_FakeProcess>();
      var calls = 0;
      final engine = FfmpegStreamDownloadEngine(
        processFactory: (executable, arguments) async {
          calls++;
          if (calls == 1) {
            await File(arguments.last).writeAsBytes([1]);
            final process = _FakeProcess.pending();
            firstStarted.complete(process);
            return process;
          }
          await File(arguments.last).writeAsBytes([1, 2, 3]);
          return _FakeProcess(exitCode: 0);
        },
      );
      final control = DownloadControl();
      final download = engine.download(
        task(),
        onProgress: onProgress,
        control: control,
      );
      final firstProcess = await firstStarted.future;

      control.pause();
      await Future<void>.delayed(Duration.zero);
      control.resume();
      final result = await download;

      expect(firstProcess.wasKilled, isTrue);
      expect(calls, 2);
      expect(result.totalBytes, 3);
    },
  );
}

class _FakeProcess implements Process {
  _FakeProcess({required int exitCode, String stderrText = ''})
    : _exitCode = Future.value(exitCode),
      _exitCompleter = null,
      stderr = Stream.value(utf8.encode(stderrText));

  _FakeProcess.pending()
    : _exitCode = null,
      _exitCompleter = Completer<int>(),
      stderr = const Stream.empty();

  final Future<int>? _exitCode;
  final Completer<int>? _exitCompleter;
  @override
  final Stream<List<int>> stderr;
  bool wasKilled = false;

  @override
  Future<int> get exitCode => _exitCode ?? _exitCompleter!.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);
  @override
  int get pid => 1;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    wasKilled = true;
    if (_exitCompleter != null && !_exitCompleter.isCompleted) {
      _exitCompleter.complete(1);
    }
    return true;
  }
}
