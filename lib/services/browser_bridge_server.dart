import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef BrowserDownloadHandler = Future<void> Function(String url);
typedef BrowserDownloadRequestHandler = Future<void> Function(
  BrowserDownloadRequest request,
);

class BrowserDownloadRequest {
  const BrowserDownloadRequest({
    required this.url,
    this.isStream = false,
    this.suggestedFileName,
    this.headers = const {},
  });

  final String url;
  final bool isStream;
  final String? suggestedFileName;
  final Map<String, String> headers;
}

class BrowserBridgeServer {
  BrowserBridgeServer._(
    this._server,
    this._token,
    this._onDownloadUrl,
    this._onDownloadRequest,
  );

  static const defaultPort = 47831;
  static const _maximumBodyBytes = 16 * 1024;

  final HttpServer _server;
  final String _token;
  final BrowserDownloadHandler? _onDownloadUrl;
  final BrowserDownloadRequestHandler? _onDownloadRequest;

  int get port => _server.port;

  static Future<BrowserBridgeServer> start({
    required String token,
    BrowserDownloadHandler? onDownloadUrl,
    BrowserDownloadRequestHandler? onDownloadRequest,
    int port = defaultPort,
  }) async {
    if (onDownloadUrl == null && onDownloadRequest == null) {
      throw ArgumentError('A browser download handler is required.');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final bridge = BrowserBridgeServer._(
      server,
      token,
      onDownloadUrl,
      onDownloadRequest,
    );
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

    final headers = _validatedRequestHeaders(message['headers']);
    if (headers == null) {
      await _respond(request, HttpStatus.badRequest, {
        'ok': false,
        'error': 'Invalid media request headers.',
      });
      return;
    }
    final requestData = BrowserDownloadRequest(
      url: url,
      isStream: message['isStream'] == true,
      suggestedFileName: message['fileName'] is String
          ? (message['fileName'] as String).trim()
          : null,
      headers: headers,
    );

    try {
      if (_onDownloadRequest != null) {
        await _onDownloadRequest(requestData);
      } else {
        await _onDownloadUrl!(url);
      }
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

Map<String, String>? _validatedRequestHeaders(Object? value) {
  if (value == null) return const {};
  if (value is! Map) return null;
  const allowedHeaders = {
    'accept',
    'cookie',
    'origin',
    'referer',
    'user-agent',
  };
  final headers = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! String) return null;
    final name = (entry.key as String).toLowerCase();
    final content = entry.value as String;
    if (!allowedHeaders.contains(name) ||
        content.contains('\r') ||
        content.contains('\n') ||
        content.length > 8192) {
      return null;
    }
    headers[name] = content;
  }
  return Map.unmodifiable(headers);
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
