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
}

void _ignoreProgress({
  required int receivedBytes,
  required int? totalBytes,
  required double bytesPerSecond,
}) {}
