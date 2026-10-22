import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef BrowserDownloadHandler = Future<void> Function(String url);

class BrowserBridgeServer {
  BrowserBridgeServer._(this._server, this._token, this._onDownloadUrl);

  static const defaultPort = 47831;
  static const _maximumBodyBytes = 16 * 1024;

  final HttpServer _server;
  final String _token;
  final BrowserDownloadHandler _onDownloadUrl;

  int get port => _server.port;

  static Future<BrowserBridgeServer> start({
    required String token,
    required BrowserDownloadHandler onDownloadUrl,
    int port = defaultPort,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final bridge = BrowserBridgeServer._(server, token, onDownloadUrl);
    server.listen(bridge._handleRequest);
    return bridge;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (!request.connectionInfo!.remoteAddress.isLoopback) {
      await _respond(request, HttpStatus.forbidden, {
        'ok': false,
        'error': 'Loopback connections only.',
      });
      return;
    }
    if (request.method != 'POST' || request.uri.path != '/downloads') {
      await _respond(request, HttpStatus.notFound, {
        'ok': false,
        'error': 'Unknown bridge endpoint.',
      });
      return;
    }
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $_token') {
      await _respond(request, HttpStatus.unauthorized, {
        'ok': false,
        'error': 'Invalid bridge token.',
      });
      return;
    }
    if (request.contentLength > _maximumBodyBytes) {
      await _respond(request, HttpStatus.requestEntityTooLarge, {
        'ok': false,
        'error': 'Request is too large.',
      });
      return;
    }

    final body = BytesBuilder(copy: false);
    await for (final chunk in request) {
      if (body.length + chunk.length > _maximumBodyBytes) {
        await _respond(request, HttpStatus.requestEntityTooLarge, {
          'ok': false,
          'error': 'Request is too large.',
        });
        return;
      }
      body.add(chunk);
    }

    final Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(utf8.decode(body.takeBytes()));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected a JSON object.');
      }
      message = decoded;
    } on FormatException {
      await _respond(request, HttpStatus.badRequest, {
        'ok': false,
        'error': 'Malformed JSON message.',
      });
      return;
    }
    if (message['type'] != 'add_download') {
      await _respond(request, HttpStatus.badRequest, {
        'ok': false,
        'error': 'Unsupported bridge message.',
      });
      return;
    }
    final url = validateDownloadUrl(message['url']);
    if (url == null) {
      await _respond(request, HttpStatus.badRequest, {
        'ok': false,
        'error': 'Only HTTP and HTTPS download URLs are supported.',
      });
      return;
    }

    try {
      await _onDownloadUrl(url);
      await _respond(request, HttpStatus.ok, {'ok': true});
    } catch (_) {
      await _respond(request, HttpStatus.internalServerError, {
        'ok': false,
        'error': 'The download could not be added to the queue.',
      });
    }
  }

  Future<void> _respond(
    HttpRequest request,
    int statusCode,
    Map<String, Object?> body,
  ) async {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

String? validateDownloadUrl(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}
