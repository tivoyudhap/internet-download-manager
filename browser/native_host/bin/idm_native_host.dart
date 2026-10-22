import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:internet_download_manager/services/browser_bridge_server.dart';
import 'package:internet_download_manager/services/native_messaging_protocol.dart';

Future<void> main() async {
  Map<String, Object?> response;
  try {
    final frame = _readFrame();
    if (frame == null) return;
    final message = decodeNativeMessage(frame);
    response = await _handleMessage(message);
  } catch (_) {
    response = {'ok': false, 'error': 'Invalid native messaging request.'};
  }
  stdout.add(encodeNativeMessage(response));
  await stdout.flush();
}

Uint8List? _readFrame() {
  final first = stdin.readByteSync();
  if (first == -1) return null;
  final header = <int>[first];
  for (var index = 1; index < 4; index++) {
    final byte = stdin.readByteSync();
    if (byte == -1) throw const FormatException('Truncated native header.');
    header.add(byte);
  }
  final length = ByteData.sublistView(Uint8List.fromList(header))
      .getUint32(0, Endian.little);
  if (length > maximumNativeMessageBytes) {
    throw const FormatException('Native message exceeds the size limit.');
  }
  final frame = Uint8List(length + 4)..setRange(0, 4, header);
  for (var index = 0; index < length; index++) {
    final byte = stdin.readByteSync();
    if (byte == -1) throw const FormatException('Truncated native body.');
    frame[index + 4] = byte;
  }
  return frame;
}

Future<Map<String, Object?>> _handleMessage(
  Map<String, dynamic> message,
) async {
  if (message['type'] != 'add_download') {
    return {'ok': false, 'error': 'Unsupported download request.'};
  }
  final url = validateDownloadUrl(message['url']);
  if (url == null) {
    return {'ok': false, 'error': 'Only HTTP and HTTPS URLs are supported.'};
  }
  final headers = _validatedHeaders(message['headers']);
  if (headers == null) {
    return {'ok': false, 'error': 'Invalid media request headers.'};
  }

  final tokenFile = File(_tokenFilePath());
  if (!await tokenFile.exists()) {
    return {'ok': false, 'error': 'Open Internet Download Manager first.'};
  }
  final token = (await tokenFile.readAsString()).trim();
  if (token.isEmpty) {
    return {'ok': false, 'error': 'Open Internet Download Manager first.'};
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client
        .postUrl(
          Uri.parse(
            'http://127.0.0.1:${BrowserBridgeServer.defaultPort}/downloads',
          ),
        )
        .timeout(const Duration(seconds: 3));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..contentType = ContentType.json;
    request.write(
      jsonEncode({
        'type': 'add_download',
        'url': url,
        'isStream': message['isStream'] == true,
        'fileName': message['fileName'],
        'headers': headers,
      }),
    );
    final response = await request.close().timeout(const Duration(seconds: 3));
    final decoded = jsonDecode(await utf8.decoder.bind(response).join());
    if (response.statusCode == HttpStatus.ok &&
        decoded is Map<String, dynamic> &&
        decoded['ok'] == true) {
      return {'ok': true, 'message': 'Download added to the queue.'};
    }
    return {
      'ok': false,
      'error': decoded is Map<String, dynamic>
          ? decoded['error']?.toString() ?? 'Could not add the download.'
          : 'Could not add the download.',
    };
  } on SocketException {
    return {'ok': false, 'error': 'Open Internet Download Manager first.'};
  } on TimeoutException {
    return {'ok': false, 'error': 'Internet Download Manager did not respond.'};
  } on FormatException {
    return {
      'ok': false,
      'error': 'Internet Download Manager returned an invalid response.',
    };
  } finally {
    client.close(force: true);
  }
}

Map<String, String>? _validatedHeaders(Object? value) {
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

String _tokenFilePath() {
  final supportDirectory = Platform.isWindows
      ? (Platform.environment['APPDATA'] ??
            '${Platform.environment['USERPROFILE'] ?? Directory.current.path}${Platform.pathSeparator}AppData${Platform.pathSeparator}Roaming')
      : '${Platform.environment['HOME'] ?? Directory.current.path}${Platform.pathSeparator}Library${Platform.pathSeparator}Application Support';
  return '$supportDirectory${Platform.pathSeparator}InternetDownloadManager${Platform.pathSeparator}browser_bridge.token';
}
