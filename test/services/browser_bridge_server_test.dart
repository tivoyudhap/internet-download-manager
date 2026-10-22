import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:internet_download_manager/services/browser_bridge_server.dart';

void main() {
  group('validateDownloadUrl', () {
    test('accepts HTTP and HTTPS URLs and trims whitespace', () {
      expect(
        validateDownloadUrl(' https://example.com/file.zip '),
        'https://example.com/file.zip',
      );
      expect(
        validateDownloadUrl('http://example.com/file.zip'),
        'http://example.com/file.zip',
      );
    });

    test('rejects blank, non-HTTP, hostless, and credentialed URLs', () {
      expect(validateDownloadUrl('  '), isNull);
      expect(validateDownloadUrl('file:///tmp/file.zip'), isNull);
      expect(validateDownloadUrl('ftp://example.com/file.zip'), isNull);
      expect(validateDownloadUrl('https:///file.zip'), isNull);
      expect(
        validateDownloadUrl('https://user:pass@example.com/file.zip'),
        isNull,
      );
      expect(validateDownloadUrl(42), isNull);
    });
  });

  group('BrowserBridgeServer', () {
    late BrowserBridgeServer bridge;
    late HttpClient client;
    final addedUrls = <String>[];
    const token = 'test-token';

    setUp(() async {
      addedUrls.clear();
      bridge = await BrowserBridgeServer.start(
        token: token,
        port: 0,
        onDownloadUrl: (url) async {
          addedUrls.add(url);
        },
      );
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await bridge.close();
    });

    Future<HttpClientResponse> post(
      String path,
      Object body, {
      String? authorization = 'Bearer test-token',
    }) async {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${bridge.port}$path'),
      );
      if (authorization != null) {
        request.headers.set(HttpHeaders.authorizationHeader, authorization);
      }
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      return request.close();
    }

    test('accepts a valid authenticated URL exactly once', () async {
      final response = await post('/downloads', {
        'type': 'add_download',
        'url': 'https://example.com/file.zip',
      });

      expect(response.statusCode, HttpStatus.ok);
      expect(jsonDecode(await response.transform(utf8.decoder).join()), {
        'ok': true,
      });
      expect(addedUrls, ['https://example.com/file.zip']);
    });

    test(
      'forwards stream metadata and session headers to the queue handler',
      () async {
        await bridge.close();
        final requests = <BrowserDownloadRequest>[];
        bridge = await BrowserBridgeServer.start(
          token: token,
          port: 0,
          onDownloadRequest: (request) async {
            requests.add(request);
          },
        );
        final response = await post('/downloads', {
          'type': 'add_download',
          'url': 'https://cdn.example.com/master.m3u8?sig=abc',
          'isStream': true,
          'fileName': 'course video',
          'headers': {
            'cookie': 'session=secret',
            'referer': 'https://site.example/watch',
          },
        });

        expect(response.statusCode, HttpStatus.ok);
        expect(requests, hasLength(1));
        expect(
          requests.single.url,
          'https://cdn.example.com/master.m3u8?sig=abc',
        );
        expect(requests.single.isStream, isTrue);
        expect(requests.single.suggestedFileName, 'course video');
        expect(requests.single.headers, {
          'cookie': 'session=secret',
          'referer': 'https://site.example/watch',
        });
      },
    );

    test('rejects unsafe or unsupported session headers', () async {
      final response = await post('/downloads', {
        'type': 'add_download',
        'url': 'https://cdn.example.com/master.m3u8',
        'isStream': true,
        'headers': {'host': 'attacker.example'},
      });

      expect(response.statusCode, HttpStatus.badRequest);
      expect(addedUrls, isEmpty);
    });

    test('rejects missing or incorrect tokens without adding a URL', () async {
      final missing = await post('/downloads', {
        'type': 'add_download',
        'url': 'https://example.com/file.zip',
      }, authorization: null);
      final incorrect = await post('/downloads', {
        'type': 'add_download',
        'url': 'https://example.com/file.zip',
      }, authorization: 'Bearer wrong');

      expect(missing.statusCode, HttpStatus.unauthorized);
      expect(incorrect.statusCode, HttpStatus.unauthorized);
      expect(addedUrls, isEmpty);
    });

    test('rejects unsupported message types and URL schemes', () async {
      final wrongType = await post('/downloads', {
        'type': 'open_file',
        'url': 'https://example.com/file.zip',
      });
      final wrongScheme = await post('/downloads', {
        'type': 'add_download',
        'url': 'file:///tmp/file.zip',
      });

      expect(wrongType.statusCode, HttpStatus.badRequest);
      expect(wrongScheme.statusCode, HttpStatus.badRequest);
      expect(addedUrls, isEmpty);
    });

    test('rejects malformed JSON, wrong routes, and wrong methods', () async {
      final malformedRequest = await client.postUrl(
        Uri.parse('http://127.0.0.1:${bridge.port}/downloads'),
      );
      malformedRequest.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..contentType = ContentType.json;
      malformedRequest.write('{invalid');
      final malformed = await malformedRequest.close();
      final wrongPath = await post('/other', {'type': 'add_download'});
      final wrongMethod = await client
          .getUrl(Uri.parse('http://127.0.0.1:${bridge.port}/downloads'))
          .then((request) => request.close());

      expect(malformed.statusCode, HttpStatus.badRequest);
      expect(wrongPath.statusCode, HttpStatus.notFound);
      expect(wrongMethod.statusCode, HttpStatus.notFound);
      expect(addedUrls, isEmpty);
    });

    test('rejects oversized bodies', () async {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${bridge.port}/downloads'),
      );
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..contentType = ContentType.json;
      request.write(' ' * (17 * 1024));
      final response = await request.close();

      expect(response.statusCode, HttpStatus.requestEntityTooLarge);
      expect(addedUrls, isEmpty);
    });

    test('returns a server error when queue insertion fails', () async {
      await bridge.close();
      bridge = await BrowserBridgeServer.start(
        token: token,
        port: 0,
        onDownloadUrl: (_) async => throw StateError('queue save failed'),
      );

      final response = await post('/downloads', {
        'type': 'add_download',
        'url': 'https://example.com/file.zip',
      });

      expect(response.statusCode, HttpStatus.internalServerError);
      expect(jsonDecode(await response.transform(utf8.decoder).join()), {
        'ok': false,
        'error': 'The download could not be added to the queue.',
      });
      expect(addedUrls, isEmpty);
    });
  });
}
