import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:internet_download_manager/models/download_task.dart';
import 'package:internet_download_manager/services/download_engine.dart';

void main() {
  late HttpServer server;
  late Directory temporaryDirectory;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    temporaryDirectory = await Directory.systemTemp.createTemp('idm-engine-');
  });

  tearDown(() async {
    await server.close(force: true);
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  DownloadTask task(String fileName) => DownloadTask.fromUrl(
    'http://${server.address.address}:${server.port}/$fileName',
    temporaryDirectory.path,
  );

  test('streams a successful response into the destination file', () async {
    final payload = List<int>.generate(128 * 1024, (index) => index % 256);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.binary;
      request.response.add(payload);
      await request.response.close();
    });
    final download = task('archive.bin');
    final progress = <int>[];

    final result = await HttpDownloadEngine().download(
      download,
      onProgress:
          ({
            required receivedBytes,
            required totalBytes,
            required bytesPerSecond,
          }) {
            progress.add(receivedBytes);
            expect(totalBytes, payload.length);
            expect(bytesPerSecond, greaterThanOrEqualTo(0));
          },
    );

    expect(result.fileName, 'archive.bin');
    expect(result.totalBytes, payload.length);
    expect(
      await File('${temporaryDirectory.path}/archive.bin').readAsBytes(),
      payload,
    );
    expect(progress, isNotEmpty);
    expect(progress.last, payload.length);
  });

  test(
    'downloads a range-capable large file using parallel segments',
    () async {
      final payload = List<int>.generate(128 * 1024, (index) => index % 251);
      var segmentRequests = 0;
      server.listen((request) async {
        final requestedRange = request.headers.value(HttpHeaders.rangeHeader)!;
        if (requestedRange == 'bytes=0-0') {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-0/${payload.length}',
          );
          request.response.add([payload.first]);
        } else {
          segmentRequests++;
          final match = RegExp(r'^bytes=(\d+)-(\d+)$')
              .firstMatch(requestedRange)!;
          final start = int.parse(match.group(1)!);
          final end = int.parse(match.group(2)!);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${payload.length}',
          );
          request.response.add(payload.sublist(start, end + 1));
        }
        await request.response.close();
      });
      final progress = <int>[];

      final result =
          await HttpDownloadEngine(
            segmentCount: 4,
            minimumSegmentedSize: 1,
          ).download(
            task('segmented.bin'),
            onProgress:
                ({
                  required receivedBytes,
                  required totalBytes,
                  required bytesPerSecond,
                }) {
                  progress.add(receivedBytes);
                  expect(totalBytes, payload.length);
                },
          );

      expect(result.totalBytes, payload.length);
      expect(segmentRequests, 4);
      expect(
        await File('${temporaryDirectory.path}/segmented.bin').readAsBytes(),
        payload,
      );
      expect(progress.last, payload.length);
      expect(progress, orderedEquals([...progress]..sort()));
      expect(await Directory(temporaryDirectory.path).list().length, 1);
    },
  );

  test(
    'resumes only missing segments left by an interrupted transfer',
    () async {
      final payload = List<int>.generate(128 * 1024, (index) => index % 239);
      final download = task('resumed-segments.bin');
      final partialPath =
          '${temporaryDirectory.path}/resumed-segments.bin.${download.id}.part';
      final savedSegment = File('$partialPath.seg1');
      const segmentLength = 128 * 1024 ~/ 4;
      await savedSegment.writeAsBytes(
        payload.sublist(segmentLength, segmentLength * 2),
      );
      await File('$partialPath.meta').writeAsString(
        '${payload.length}\n${HttpHeaders.etagHeader}\n"stable-v1"',
      );
      final requestedRanges = <String>[];
      server.listen((request) async {
        final requestedRange = request.headers.value(HttpHeaders.rangeHeader)!;
        requestedRanges.add(requestedRange);
        request.response.headers.set(HttpHeaders.etagHeader, '"stable-v1"');
        if (requestedRange == 'bytes=0-0') {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-0/${payload.length}',
          );
          request.response.add([payload.first]);
        } else {
          final match = RegExp(r'^bytes=(\d+)-(\d+)$')
              .firstMatch(requestedRange)!;
          final start = int.parse(match.group(1)!);
          final end = int.parse(match.group(2)!);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${payload.length}',
          );
          request.response.add(payload.sublist(start, end + 1));
        }
        await request.response.close();
      });

      final result = await HttpDownloadEngine(minimumSegmentedSize: 1)
          .download(download, onProgress: _ignoreProgress);

      expect(result.totalBytes, payload.length);
      expect(requestedRanges, hasLength(4));
      expect(
        requestedRanges,
        isNot(contains('bytes=$segmentLength-${segmentLength * 2 - 1}')),
      );
      expect(
        await File('${temporaryDirectory.path}/resumed-segments.bin')
            .readAsBytes(),
        payload,
      );
      expect(await savedSegment.exists(), isFalse);
    },
  );

  test('rejects a segment response with a mismatched Content-Range', () async {
    final payload = List<int>.generate(128 * 1024, (index) => index % 233);
    server.listen((request) async {
      final requestedRange = request.headers.value(HttpHeaders.rangeHeader)!;
      if (requestedRange == 'bytes=0-0') {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-0/${payload.length}',
        );
        request.response.add([payload.first]);
      } else {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-0/${payload.length}',
        );
        request.response.add([payload.first]);
      }
      await request.response.close();
    });

    await expectLater(
      HttpDownloadEngine(minimumSegmentedSize: 1)
          .download(task('invalid-segment.bin'), onProgress: _ignoreProgress),
      throwsA(
        isA<DownloadException>().having(
          (error) => error.message,
          'message',
          'Server returned an invalid byte range for a segment.',
        ),
      ),
    );
    expect(
      await File('${temporaryDirectory.path}/invalid-segment.bin').exists(),
      isFalse,
    );
  });

  test(
    'splits uneven file sizes into complete non-overlapping ranges',
    () async {
      final payload = List<int>.generate(
        128 * 1024 + 3,
        (index) => index % 227,
      );
      final ranges = <String>[];
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader)!;
        ranges.add(range);
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${payload.length}',
        );
        request.response.add(payload.sublist(start, end + 1));
        await request.response.close();
      });

      final result = await HttpDownloadEngine(
        segmentCount: 4,
        minimumSegmentedSize: 1,
      ).download(task('uneven.bin'), onProgress: _ignoreProgress);

      expect(result.totalBytes, payload.length);
      expect(ranges, contains('bytes=0-0'));
      expect(ranges, contains('bytes=0-${payload.length ~/ 4 - 1}'));
      expect(
        ranges,
        contains('bytes=${payload.length ~/ 4}-${payload.length ~/ 2 - 1}'),
      );
      expect(
        await File('${temporaryDirectory.path}/uneven.bin').readAsBytes(),
        payload,
      );
    },
  );

  test('continues partial segments and discards oversized segment files', () async {
    final payload = List<int>.generate(128 * 1024, (index) => index % 223);
    final download = task('recovered-segments.bin');
    final partialPath =
        '${temporaryDirectory.path}/recovered-segments.bin.${download.id}.part';
    const segmentLength = 128 * 1024 ~/ 4;
    final partialSegment = File('$partialPath.seg0');
    final oversizedSegment = File('$partialPath.seg1');
    final completeSegment2 = File('$partialPath.seg2');
    final completeSegment3 = File('$partialPath.seg3');
    await partialSegment.writeAsBytes(payload.sublist(0, 100));
    await oversizedSegment.writeAsBytes(List.filled(segmentLength + 1, 0));
    await completeSegment2.writeAsBytes(
      payload.sublist(segmentLength * 2, segmentLength * 3),
    );
    await completeSegment3.writeAsBytes(payload.sublist(segmentLength * 3));
    await File('$partialPath.meta').writeAsString(
      '${payload.length}\n${HttpHeaders.etagHeader}\n"stable-v1"',
    );
    final ranges = <String>[];
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      ranges.add(range);
      request.response.headers.set(HttpHeaders.etagHeader, '"stable-v1"');
      if (range == 'bytes=0-0') {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-0/${payload.length}',
        );
        request.response.add([payload.first]);
      } else {
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${payload.length}',
        );
        request.response.add(payload.sublist(start, end + 1));
      }
      await request.response.close();
    });

    final result = await HttpDownloadEngine(minimumSegmentedSize: 1)
        .download(download, onProgress: _ignoreProgress);

    expect(result.totalBytes, payload.length);
    expect(ranges, contains('bytes=100-${segmentLength - 1}'));
    expect(ranges, contains('bytes=$segmentLength-${segmentLength * 2 - 1}'));
    expect(
      ranges,
      isNot(contains('bytes=${segmentLength * 2}-${segmentLength * 3 - 1}')),
    );
    expect(
      await File('${temporaryDirectory.path}/recovered-segments.bin')
          .readAsBytes(),
      payload,
    );
  });

  test('rejects a failed HTTP response for a segment', () async {
    final payload = List<int>.generate(128 * 1024, (index) => index % 211);
    server.listen((request) async {
      if (request.headers.value(HttpHeaders.rangeHeader) == 'bytes=0-0') {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-0/${payload.length}',
        );
        request.response.add([payload.first]);
      } else {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      }
      await request.response.close();
    });

    await expectLater(
      HttpDownloadEngine(
        minimumSegmentedSize: 1,
      ).download(task('segment-server-error.bin'), onProgress: _ignoreProgress),
      throwsA(
        isA<DownloadException>().having(
          (error) => error.message,
          'message',
          'Server returned an invalid byte range for a segment.',
        ),
      ),
    );
    expect(
      await File('${temporaryDirectory.path}/segment-server-error.bin')
          .exists(),
      isFalse,
    );
  });

  test('retries a truncated segment from its saved byte offset', () async {
    final payload = List<int>.generate(128 * 1024, (index) => index % 197);
    const segmentLength = 128 * 1024 ~/ 4;
    final requestedRanges = <String>[];
    var shouldTruncateFirstSegment = true;
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      requestedRanges.add(range);
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(HttpHeaders.etagHeader, '"retry-v1"');
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${payload.length}',
      );
      if (range == 'bytes=0-0') {
        request.response.add([payload.first]);
      } else if (start == 0 && shouldTruncateFirstSegment) {
        shouldTruncateFirstSegment = false;
        request.response.contentLength = end - start + 1;
        final socket = await request.response.detachSocket(writeHeaders: true);
        socket.add(payload.sublist(start, start + 100));
        await socket.flush();
        await socket.close();
        return;
      } else {
        request.response.add(payload.sublist(start, end + 1));
      }
      await request.response.close();
    });
    final download = task('retry-segment.bin');
    final engine = HttpDownloadEngine(minimumSegmentedSize: 1);

    await expectLater(
      engine.download(download, onProgress: _ignoreProgress),
      throwsA(isA<DownloadException>()),
    );
    final partialSegment = File(
      '${temporaryDirectory.path}/retry-segment.bin.${download.id}.part.seg0',
    );
    expect(await partialSegment.length(), 100);

    final result = await engine.download(download, onProgress: _ignoreProgress);

    expect(result.totalBytes, payload.length);
    expect(requestedRanges, contains('bytes=100-${segmentLength - 1}'));
    expect(
      await File('${temporaryDirectory.path}/retry-segment.bin').readAsBytes(),
      payload,
    );
  });

  test('pauses segmented assembly until resumed and then completes', () async {
    final payload = List<int>.generate(128 * 1024, (index) => index % 199);
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${payload.length}',
      );
      request.response.add(payload.sublist(start, end + 1));
      await request.response.close();
    });
    final paused = Completer<void>();
    final control = DownloadControl();
    final downloadFuture = HttpDownloadEngine(minimumSegmentedSize: 1).download(
      task('paused-segments.bin'),
      control: control,
      onProgress:
          ({
            required receivedBytes,
            required totalBytes,
            required bytesPerSecond,
          }) {
            if (!control.isPaused && receivedBytes > 0) {
              control.pause();
              if (!paused.isCompleted) paused.complete();
            }
          },
    );

    await paused.future;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      await File('${temporaryDirectory.path}/paused-segments.bin').exists(),
      isFalse,
    );
    control.resume();
    final result = await downloadFuture;

    expect(result.totalBytes, payload.length);
    expect(
      await File('${temporaryDirectory.path}/paused-segments.bin')
          .readAsBytes(),
      payload,
    );
  });

  test(
    'cancels active segmented requests without publishing a final file',
    () async {
      final payload = List<int>.generate(128 * 1024, (index) => index % 193);
      final segmentRequestReceived = Completer<void>();
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader)!;
        if (range == 'bytes=0-0') {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-0/${payload.length}',
          );
          request.response.add([payload.first]);
          await request.response.close();
          return;
        }
        if (!segmentRequestReceived.isCompleted) {
          segmentRequestReceived.complete();
        }
        request.response.contentLength = payload.length;
        request.response.add([payload.first]);
        await request.response.flush();
        await Completer<void>().future;
      });
      final control = DownloadControl();
      final downloadFuture = HttpDownloadEngine(minimumSegmentedSize: 1)
          .download(
            task('canceled-segments.bin'),
            onProgress: _ignoreProgress,
            control: control,
          );

      await segmentRequestReceived.future;
      control.cancel();

      await expectLater(
        downloadFuture,
        throwsA(isA<DownloadCanceledException>()),
      );
      expect(
        await File('${temporaryDirectory.path}/canceled-segments.bin').exists(),
        isFalse,
      );
    },
  );

  test(
    'falls back to a full response when the ranged file is too small',
    () async {
      const payload = 'small ranged response';
      var fullResponseRequests = 0;
      server.listen((request) async {
        if (request.headers.value(HttpHeaders.rangeHeader) == 'bytes=0-0') {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-0/${payload.length}',
          );
          request.response.add([payload.codeUnitAt(0)]);
        } else {
          fullResponseRequests++;
          request.response.write(payload);
        }
        await request.response.close();
      });

      final result = await HttpDownloadEngine().download(
        task('small-ranged.txt'),
        onProgress: _ignoreProgress,
      );

      expect(result.totalBytes, payload.length);
      expect(fullResponseRequests, 1);
      expect(
        await File('${temporaryDirectory.path}/small-ranged.txt')
            .readAsString(),
        payload,
      );
    },
  );

  test(
    'reuses saved segments only when the source ETag still matches',
    () async {
      final oldPayload = List<int>.filled(128 * 1024, 3);
      final payload = List<int>.generate(128 * 1024, (index) => index % 181);
      final download = task('changed-source.bin');
      final partialPath =
          '${temporaryDirectory.path}/changed-source.bin.${download.id}.part';
      const segmentLength = 128 * 1024 ~/ 4;
      final oldSegment = File('$partialPath.seg0');
      await oldSegment.writeAsBytes(oldPayload.sublist(0, segmentLength));
      await File(
        '$partialPath.meta',
      ).writeAsString('${payload.length}\n${HttpHeaders.etagHeader}\n"old-v1"');
      final ranges = <String>[];
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader)!;
        ranges.add(range);
        if (range != 'bytes=0-0') {
          expect(request.headers.value('if-range'), '"new-v2"');
        }
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(HttpHeaders.etagHeader, '"new-v2"');
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${payload.length}',
        );
        request.response.add(payload.sublist(start, end + 1));
        await request.response.close();
      });

      final result = await HttpDownloadEngine(minimumSegmentedSize: 1)
          .download(download, onProgress: _ignoreProgress);

      expect(result.totalBytes, payload.length);
      expect(ranges, contains('bytes=0-32767'));
      expect(
        await File('${temporaryDirectory.path}/changed-source.bin')
            .readAsBytes(),
        payload,
      );
      expect(await oldSegment.exists(), isFalse);
    },
  );

  test('does not resume segments when the server provides no validator', () async {
    final oldPayload = List<int>.filled(128 * 1024, 4);
    final payload = List<int>.generate(128 * 1024, (index) => index % 179);
    final download = task('unvalidated-source.bin');
    final partialPath =
        '${temporaryDirectory.path}/unvalidated-source.bin.${download.id}.part';
    const segmentLength = 128 * 1024 ~/ 4;
    final staleSegment = File('$partialPath.seg1');
    await staleSegment.writeAsBytes(
      oldPayload.sublist(segmentLength, segmentLength * 2),
    );
    final ranges = <String>[];
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      ranges.add(range);
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${payload.length}',
      );
      request.response.add(payload.sublist(start, end + 1));
      await request.response.close();
    });

    final result = await HttpDownloadEngine(minimumSegmentedSize: 1)
        .download(download, onProgress: _ignoreProgress);

    expect(result.totalBytes, payload.length);
    expect(ranges, contains('bytes=$segmentLength-${segmentLength * 2 - 1}'));
    expect(
      await File('${temporaryDirectory.path}/unvalidated-source.bin')
          .readAsBytes(),
      payload,
    );
    expect(await staleSegment.exists(), isFalse);
  });

  test('uses Last-Modified with If-Range when no strong ETag is available', () async {
    final payload = List<int>.generate(128 * 1024, (index) => index % 177);
    final download = task('last-modified-source.bin');
    final partialPath =
        '${temporaryDirectory.path}/last-modified-source.bin.${download.id}.part';
    const segmentLength = 128 * 1024 ~/ 4;
    final savedSegment = File('$partialPath.seg0');
    await savedSegment.writeAsBytes(payload.sublist(0, segmentLength));
    const modified = 'Wed, 21 Oct 2015 07:28:00 GMT';
    await File('$partialPath.meta').writeAsString(
      '${payload.length}\n${HttpHeaders.lastModifiedHeader}\n$modified',
    );
    final ranges = <String>[];
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      ranges.add(range);
      if (range != 'bytes=0-0') {
        expect(request.headers.value('if-range'), modified);
      }
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(HttpHeaders.lastModifiedHeader, modified);
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${payload.length}',
      );
      request.response.add(payload.sublist(start, end + 1));
      await request.response.close();
    });

    final result = await HttpDownloadEngine(minimumSegmentedSize: 1)
        .download(download, onProgress: _ignoreProgress);

    expect(result.totalBytes, payload.length);
    expect(ranges, isNot(contains('bytes=0-${segmentLength - 1}')));
    expect(
      await File('${temporaryDirectory.path}/last-modified-source.bin')
          .readAsBytes(),
      payload,
    );
  });

  test(
    'discards all segments when If-Range reports the source changed',
    () async {
      final payload = List<int>.generate(128 * 1024, (index) => index % 173);
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader)!;
        if (range == 'bytes=0-0') {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(HttpHeaders.etagHeader, '"source-v1"');
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-0/${payload.length}',
          );
          request.response.add([payload.first]);
        } else {
          expect(request.headers.value('if-range'), '"source-v1"');
          request.response.statusCode = HttpStatus.ok;
          request.response.add(payload);
        }
        await request.response.close();
      });
      final download = task('source-changed.bin');

      await expectLater(
        HttpDownloadEngine(minimumSegmentedSize: 1)
            .download(download, onProgress: _ignoreProgress),
        throwsA(
          isA<DownloadException>().having(
            (error) => error.message,
            'message',
            'The remote file changed during the segmented download. Retry to start over.',
          ),
        ),
      );

      expect(
        await File('${temporaryDirectory.path}/source-changed.bin').exists(),
        isFalse,
      );
      expect(await Directory(temporaryDirectory.path).list().toList(), isEmpty);
    },
  );

  test('follows redirects for the probe and every parallel segment', () async {
    final payload = List<int>.generate(128 * 1024, (index) => index % 167);
    var redirectedRangeRequests = 0;
    server.listen((request) async {
      if (request.uri.path == '/redirected-large.bin') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/actual-large.bin',
        );
        await request.response.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      if (range != 'bytes=0-0') redirectedRangeRequests++;
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(HttpHeaders.etagHeader, '"redirect-v1"');
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${payload.length}',
      );
      request.response.add(payload.sublist(start, end + 1));
      await request.response.close();
    });
    final redirectedTask = DownloadTask.fromUrl(
      'http://${server.address.address}:${server.port}/redirected-large.bin',
      temporaryDirectory.path,
    );

    final result = await HttpDownloadEngine(minimumSegmentedSize: 1)
        .download(redirectedTask, onProgress: _ignoreProgress);

    expect(result.totalBytes, payload.length);
    expect(redirectedRangeRequests, 4);
    expect(
      await File('${temporaryDirectory.path}/redirected-large.bin')
          .readAsBytes(),
      payload,
    );
  });

  test(
    'starts every segment request before any segment response completes',
    () async {
      final payload = List<int>.generate(128 * 1024, (index) => index % 163);
      final allSegmentsReceived = Completer<void>();
      var activeSegmentRequests = 0;
      var maximumActiveSegmentRequests = 0;
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader)!;
        if (range == 'bytes=0-0') {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-0/${payload.length}',
          );
          request.response.add([payload.first]);
          await request.response.close();
          return;
        }
        activeSegmentRequests++;
        if (activeSegmentRequests > maximumActiveSegmentRequests) {
          maximumActiveSegmentRequests = activeSegmentRequests;
        }
        if (activeSegmentRequests == 4 && !allSegmentsReceived.isCompleted) {
          allSegmentsReceived.complete();
        }
        await allSegmentsReceived.future.timeout(const Duration(seconds: 2));
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(HttpHeaders.etagHeader, '"parallel-v1"');
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${payload.length}',
        );
        request.response.add(payload.sublist(start, end + 1));
        await request.response.close();
        activeSegmentRequests--;
      });

      final result = await HttpDownloadEngine(minimumSegmentedSize: 1)
          .download(task('parallel-proof.bin'), onProgress: _ignoreProgress);

      expect(result.totalBytes, payload.length);
      expect(maximumActiveSegmentRequests, 4);
    },
  );

  test(
    'falls back when the range probe has a malformed Content-Range',
    () async {
      const payload = 'fallback after a malformed range probe';
      var fullRequests = 0;
      server.listen((request) async {
        if (request.headers.value(HttpHeaders.rangeHeader) == 'bytes=0-0') {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'invalid',
          );
          request.response.add([payload.codeUnitAt(0)]);
        } else {
          fullRequests++;
          request.response.write(payload);
        }
        await request.response.close();
      });

      final result = await HttpDownloadEngine().download(
        task('malformed-probe.txt'),
        onProgress: _ignoreProgress,
      );

      expect(result.totalBytes, payload.length);
      expect(fullRequests, 1);
      expect(
        await File('${temporaryDirectory.path}/malformed-probe.txt')
            .readAsString(),
        payload,
      );
    },
  );

  test(
    'uses two valid segments when file size is below configured segment count',
    () async {
      const payload = <int>[17, 42];
      final ranges = <String>[];
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader)!;
        ranges.add(range);
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${payload.length}',
        );
        request.response.add(payload.sublist(start, end + 1));
        await request.response.close();
      });

      final result = await HttpDownloadEngine(
        segmentCount: 4,
        minimumSegmentedSize: 2,
      ).download(task('two-byte.bin'), onProgress: _ignoreProgress);

      expect(result.totalBytes, 2);
      expect(ranges, containsAll(['bytes=0-0', 'bytes=1-1']));
      expect(
        await File('${temporaryDirectory.path}/two-byte.bin').readAsBytes(),
        payload,
      );
    },
  );

  test('falls back safely for a one-byte ranged file', () async {
    const payload = <int>[81];
    var fullRequests = 0;
    server.listen((request) async {
      if (request.headers.value(HttpHeaders.rangeHeader) == 'bytes=0-0') {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-0/1',
        );
        request.response.add(payload);
      } else {
        fullRequests++;
        request.response.add(payload);
      }
      await request.response.close();
    });

    final result = await HttpDownloadEngine(minimumSegmentedSize: 1)
        .download(task('one-byte.bin'), onProgress: _ignoreProgress);

    expect(result.totalBytes, 1);
    expect(fullRequests, 1);
    expect(
      await File('${temporaryDirectory.path}/one-byte.bin').readAsBytes(),
      payload,
    );
  });

  test('rejects a segment body longer than its requested byte range', () async {
    final payload = List<int>.generate(128 * 1024, (index) => index % 191);
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${payload.length}',
      );
      if (range == 'bytes=0-0') {
        request.response.add([payload.first]);
      } else {
        request.response.add([...payload.sublist(start, end + 1), 255]);
      }
      await request.response.close();
    });

    await expectLater(
      HttpDownloadEngine(minimumSegmentedSize: 1)
          .download(task('long-segment.bin'), onProgress: _ignoreProgress),
      throwsA(isA<DownloadException>()),
    );
    expect(
      await File('${temporaryDirectory.path}/long-segment.bin').exists(),
      isFalse,
    );
  });

  test(
    'uses a numbered filename when the destination already exists',
    () async {
      server.listen((request) async {
        request.response.write('new content');
        await request.response.close();
      });
      await File('${temporaryDirectory.path}/report.txt').writeAsString('keep');

      final result = await HttpDownloadEngine().download(
        task('report.txt'),
        onProgress: _ignoreProgress,
      );

      expect(result.fileName, 'report (1).txt');
      expect(
        await File('${temporaryDirectory.path}/report.txt').readAsString(),
        'keep',
      );
      expect(
        await File('${temporaryDirectory.path}/report (1).txt').readAsString(),
        'new content',
      );
    },
  );

  test('follows an HTTP redirect to the final file response', () async {
    server.listen((request) async {
      if (request.uri.path == '/old.zip') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/new.zip');
      } else {
        request.response.write('redirected content');
      }
      await request.response.close();
    });

    final result = await HttpDownloadEngine().download(
      task('old.zip'),
      onProgress: _ignoreProgress,
    );

    expect(result.totalBytes, 'redirected content'.length);
    expect(
      await File('${temporaryDirectory.path}/old.zip').readAsString(),
      'redirected content',
    );
  });

  test(
    'reports non-success HTTP responses without creating a final file',
    () async {
      server.listen((request) async {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('missing');
        await request.response.close();
      });
      final download = task('missing.zip');

      await expectLater(
        HttpDownloadEngine().download(download, onProgress: _ignoreProgress),
        throwsA(
          isA<DownloadException>().having(
            (error) => error.message,
            'message',
            'Server returned HTTP 404.',
          ),
        ),
      );
      expect(
        await File('${temporaryDirectory.path}/missing.zip').exists(),
        isFalse,
      );
    },
  );

  test(
    'retains a partial file and reports a short response as failed',
    () async {
      server.listen((request) async {
        request.response.headers.contentLength = 20;
        final socket = await request.response.detachSocket(writeHeaders: true);
        socket.add([1, 2, 3, 4]);
        await socket.flush();
        await socket.close();
      });
      final download = task('truncated.bin');

      await expectLater(
        HttpDownloadEngine().download(download, onProgress: _ignoreProgress),
        throwsA(isA<DownloadException>()),
      );
      expect(
        await File('${temporaryDirectory.path}/truncated.bin').exists(),
        isFalse,
      );
      expect(
        await File(
          '${temporaryDirectory.path}/truncated.bin.${download.id}.part',
        ).exists(),
        isTrue,
      );
    },
  );

  test('accepts an empty response and creates an empty file', () async {
    server.listen((request) async {
      request.response.contentLength = 0;
      await request.response.close();
    });

    final result = await HttpDownloadEngine().download(
      task('empty.bin'),
      onProgress: _ignoreProgress,
    );

    expect(result.totalBytes, 0);
    expect(await File('${temporaryDirectory.path}/empty.bin').length(), 0);
  });

  test('handles chunked responses with no declared content length', () async {
    server.listen((request) async {
      request.response.headers.chunkedTransferEncoding = true;
      request.response.write('chunked payload');
      await request.response.close();
    });

    final result = await HttpDownloadEngine().download(
      task('chunked.txt'),
      onProgress: _ignoreProgress,
    );

    expect(result.totalBytes, 'chunked payload'.length);
    expect(
      await File('${temporaryDirectory.path}/chunked.txt').readAsString(),
      'chunked payload',
    );
  });

  test(
    'resumes an existing partial file using an HTTP range request',
    () async {
      final download = task('resume.bin');
      final partial = File(
        '${temporaryDirectory.path}/resume.bin.${download.id}.part',
      );
      await partial.writeAsBytes([1, 2]);
      server.listen((request) async {
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=2-');
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 2-5/6',
        );
        request.response.contentLength = 4;
        request.response.add([3, 4, 5, 6]);
        await request.response.close();
      });

      final result = await HttpDownloadEngine().download(
        download,
        onProgress: _ignoreProgress,
      );

      expect(result.totalBytes, 6);
      expect(
        await File('${temporaryDirectory.path}/resume.bin').readAsBytes(),
        [1, 2, 3, 4, 5, 6],
      );
      expect(await partial.exists(), isFalse);
    },
  );

  test(
    'restarts from zero when the server ignores the range request',
    () async {
      final download = task('restart.bin');
      await File('${temporaryDirectory.path}/restart.bin.${download.id}.part')
          .writeAsBytes([1, 2, 3]);
      server.listen((request) async {
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=3-');
        request.response.add([9, 8]);
        await request.response.close();
      });

      final result = await HttpDownloadEngine().download(
        download,
        onProgress: _ignoreProgress,
      );

      expect(result.totalBytes, 2);
      expect(
        await File('${temporaryDirectory.path}/restart.bin').readAsBytes(),
        [9, 8],
      );
    },
  );

  test(
    'finalizes a partial file when the server reports it is already complete',
    () async {
      final download = task('already-complete.bin');
      final partial = File(
        '${temporaryDirectory.path}/already-complete.bin.${download.id}.part',
      );
      await partial.writeAsBytes([1, 2, 3]);
      server.listen((request) async {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */3',
        );
        await request.response.close();
      });

      final result = await HttpDownloadEngine().download(
        download,
        onProgress: _ignoreProgress,
      );

      expect(result.totalBytes, 3);
      expect(
        await File('${temporaryDirectory.path}/already-complete.bin')
            .readAsBytes(),
        [1, 2, 3],
      );
    },
  );

  test('maps connection failures into a readable download error', () async {
    final unavailablePort = server.port;
    final host = server.address.address;
    await server.close(force: true);
    final download = DownloadTask.fromUrl(
      'http://$host:$unavailablePort/unreachable.bin',
      temporaryDirectory.path,
    );

    await expectLater(
      HttpDownloadEngine().download(download, onProgress: _ignoreProgress),
      throwsA(
        isA<DownloadException>().having(
          (error) => error.message,
          'message',
          startsWith('Network error:'),
        ),
      ),
    );
  });

  test('reports a destination path that cannot be created', () async {
    final blockedPath = File('${temporaryDirectory.path}/blocked');
    await blockedPath.writeAsString('not a directory');
    final download = DownloadTask.fromUrl(
      'http://${server.address.address}:${server.port}/blocked.bin',
      blockedPath.path,
    );

    await expectLater(
      HttpDownloadEngine().download(download, onProgress: _ignoreProgress),
      throwsA(
        isA<DownloadException>().having(
          (error) => error.message,
          'message',
          startsWith('File error:'),
        ),
      ),
    );
  });

  test('pauses transfer work until the control is resumed', () async {
    final control = DownloadControl()..pause();
    var resumed = false;
    final waiting = control.waitUntilResumed().then((_) => resumed = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(resumed, isFalse);

    control.resume();
    await waiting;
    expect(resumed, isTrue);
  });

  test('cancels a paused transfer and wakes its waiter', () async {
    final control = DownloadControl()..pause();
    final waiting = control.waitUntilResumed();
    control.cancel();

    await expectLater(waiting, throwsA(isA<DownloadCanceledException>()));
    expect(control.isCanceled, isTrue);
  });

  test('cancellation closes the active HTTP client', () async {
    final responseStarted = Completer<void>();
    server.listen((request) async {
      request.response.contentLength = 100000;
      request.response.add([1, 2, 3]);
      await request.response.flush();
      responseStarted.complete();
      await Completer<void>().future;
    });
    final control = DownloadControl();
    final download = HttpDownloadEngine().download(
      task('canceled.bin'),
      onProgress: _ignoreProgress,
      control: control,
    );
    await responseStarted.future;
    control.cancel();

    await expectLater(download, throwsA(isA<DownloadCanceledException>()));
    expect(
      await File('${temporaryDirectory.path}/canceled.bin').exists(),
      isFalse,
    );
  });

  test('cancels while waiting for the response headers', () async {
    final requestReceived = Completer<void>();
    server.listen((request) async {
      requestReceived.complete();
      await Completer<void>().future;
    });
    final control = DownloadControl();
    final download = HttpDownloadEngine().download(
      task('waiting.bin'),
      onProgress: _ignoreProgress,
      control: control,
    );
    await requestReceived.future;
    control.cancel();

    await expectLater(download, throwsA(isA<DownloadCanceledException>()));
  });
}

void _ignoreProgress({
  required int receivedBytes,
  required int? totalBytes,
  required double bytesPerSecond,
}) {}
