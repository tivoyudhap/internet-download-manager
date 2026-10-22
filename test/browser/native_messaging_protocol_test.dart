import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:internet_download_manager/services/native_messaging_protocol.dart';

void main() {
  group('native messaging frame', () {
    test('round trips a JSON request with a little-endian length header', () {
      final frame = encodeNativeMessage({
        'type': 'add_download',
        'url': 'https://example.com/file.zip',
      });

      expect(
        ByteData.sublistView(frame).getUint32(0, Endian.little),
        frame.length - 4,
      );
      expect(decodeNativeMessage(frame), {
        'type': 'add_download',
        'url': 'https://example.com/file.zip',
      });
    });

    test('round trips non-ASCII payloads as UTF-8', () {
      final frame = encodeNativeMessage({'url': 'https://example.com/文件.zip'});

      expect(decodeNativeMessage(frame)['url'], 'https://example.com/文件.zip');
    });

    test('rejects a truncated header', () {
      expect(
        () => decodeNativeMessage(Uint8List.fromList([1, 0, 0])),
        throwsFormatException,
      );
    });

    test('rejects a length that does not match the frame body', () {
      expect(
        () => decodeNativeMessage(Uint8List.fromList([2, 0, 0, 0, 123])),
        throwsFormatException,
      );
    });

    test('rejects oversized frames before decoding their body', () {
      final frame = Uint8List(4);
      ByteData.sublistView(frame)
          .setUint32(0, maximumNativeMessageBytes + 1, Endian.little);

      expect(() => decodeNativeMessage(frame), throwsFormatException);
    });

    test('rejects non-object JSON messages', () {
      expect(
        () => decodeNativeMessage(encodeNativeMessage(['not', 'an object'])),
        throwsFormatException,
      );
    });
  });
}
