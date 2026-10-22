import 'dart:convert';
import 'dart:typed_data';

const maximumNativeMessageBytes = 1024 * 1024;

Map<String, dynamic> decodeNativeMessage(Uint8List frame) {
  if (frame.length < 4) {
    throw const FormatException('Native message frame is missing its header.');
  }
  final length = ByteData.sublistView(frame, 0, 4).getUint32(0, Endian.little);
  if (length > maximumNativeMessageBytes) {
    throw const FormatException('Native message exceeds the size limit.');
  }
  if (frame.length != length + 4) {
    throw const FormatException('Native message frame length is invalid.');
  }
  final decoded = jsonDecode(utf8.decode(frame.sublist(4)));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Native message must be a JSON object.');
  }
  return decoded;
}

Uint8List encodeNativeMessage(Object message) {
  final payload = utf8.encode(jsonEncode(message));
  if (payload.length > maximumNativeMessageBytes) {
    throw const FormatException('Native message exceeds the size limit.');
  }
  final frame = Uint8List(payload.length + 4);
  ByteData.sublistView(frame, 0, 4).setUint32(
    0,
    payload.length,
    Endian.little,
  );
  frame.setRange(4, frame.length, payload);
  return frame;
}
