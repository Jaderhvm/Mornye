import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/blowfish.dart';
import 'package:pointycastle/block/modes/cbc.dart';

/// A plugin's declarative, in-memory audio source. Never persist keys or URLs.
class ExtensionAudioSource {
  ExtensionAudioSource.fromJson(Map<String, dynamic> json)
    : url = Uri.parse(json['url'] as String? ?? ''),
      headers = Map<String, String>.from(json['headers'] as Map? ?? {}),
      mimeType = json['mime_type'] as String? ?? 'application/octet-stream',
      transform = json['transform'] == null
          ? null
          : AudioBlockTransform.fromJson(
              Map<String, dynamic>.from(json['transform'] as Map),
            ) {
    if (json['success'] != true) {
      throw StateError(
        json['error_type'] == 'verification_required'
            ? 'Verify the extension session in Settings before playback.'
            : 'The extension could not provide an audio source.',
      );
    }
    if (!{'http', 'https'}.contains(url.scheme) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasFragment) {
      throw const FormatException('Invalid extension audio URL');
    }
    const reserved = {
      'host',
      'range',
      'connection',
      'content-length',
      'transfer-encoding',
      'accept-encoding',
    };
    for (final entry in headers.entries) {
      if (!RegExp(r'^[!#$%&\x27*+.^_`|~0-9A-Za-z-]+$').hasMatch(entry.key) ||
          reserved.contains(entry.key.toLowerCase()) ||
          RegExp(r'[\r\n]').hasMatch(entry.value)) {
        throw const FormatException('Invalid extension audio headers');
      }
    }
    if (RegExp(r'[\r\n]').hasMatch(mimeType)) {
      throw const FormatException('Invalid audio MIME type');
    }
  }
  final Uri url;
  final Map<String, String> headers;
  final String mimeType;
  final AudioBlockTransform? transform;
}

class AudioBlockTransform {
  AudioBlockTransform.fromJson(Map<String, dynamic> json)
    : key = _hex(json['key_hex']),
      iv = _hex(json['iv_hex']),
      segmentSize = (json['segment_size'] as num?)?.toInt() ?? 0,
      every = (json['transform_every'] as num?)?.toInt() ?? 0,
      offset = (json['transform_offset'] as num?)?.toInt() ?? 0 {
    if (json['algorithm'] != 'blowfish-cbc' ||
        key.length < 4 ||
        key.length > 56 ||
        iv.length != 8 ||
        segmentSize < 8 ||
        segmentSize > 65536 ||
        segmentSize % 8 != 0 ||
        every < 1 ||
        every > 64 ||
        offset < 0 ||
        offset >= every) {
      throw const FormatException('Unsupported audio block transform');
    }
  }
  final Uint8List key, iv;
  final int segmentSize, every, offset;
  static Uint8List _hex(dynamic value) {
    final text = value is String ? value : '';
    if (text.isEmpty ||
        text.length.isOdd ||
        !RegExp(r'^[a-fA-F0-9]+$').hasMatch(text)) {
      throw const FormatException('Invalid audio transform parameters');
    }
    return Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
  }

  /// Each selected segment resets CBC independently. A partial final segment
  /// is deliberately left untouched, matching the provider's download path.
  Uint8List decode(Uint8List bytes, int absoluteSegment) {
    if (bytes.length != segmentSize || absoluteSegment % every != offset) {
      return bytes;
    }
    final cipher = CBCBlockCipher(BlowfishEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    final output = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i += 8) {
      cipher.processBlock(bytes, i, output, i);
    }
    return output;
  }

  Stream<List<int>> decodeStream(
    Stream<List<int>> input,
    int startByte,
  ) async* {
    if (startByte % segmentSize != 0) throw ArgumentError('Unaligned source');
    var segment = startByte ~/ segmentSize;
    var buffer = Uint8List(segmentSize);
    var filled = 0;
    await for (final chunk in input) {
      var position = 0;
      while (position < chunk.length) {
        final length = (segmentSize - filled).clamp(0, chunk.length - position);
        buffer.setRange(filled, filled + length, chunk, position);
        filled += length;
        position += length;
        if (filled == segmentSize) {
          yield decode(buffer, segment++);
          buffer = Uint8List(segmentSize);
          filled = 0;
        }
      }
    }
    if (filled != 0) yield Uint8List.sublistView(buffer, 0, filled);
  }
}

class AudioByteRange {
  const AudioByteRange(this.start, this.end);
  final int start;
  final int? end;
  static AudioByteRange? parse(String? header) {
    if (header == null) return null;
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header);
    if (match == null) throw const FormatException('Unsupported byte range');
    final start = int.parse(match[1]!);
    final end = match[2]!.isEmpty ? null : int.parse(match[2]!);
    if (end != null && end < start) {
      throw const FormatException('Invalid byte range');
    }
    return AudioByteRange(start, end);
  }

  int alignedStart(int blockSize) => start ~/ blockSize * blockSize;
  int? alignedEnd(int blockSize) =>
      end == null ? null : ((end! ~/ blockSize) + 1) * blockSize - 1;
}

bool audioHostAllowed(Uri url, List<String> permissions) {
  if (url.scheme != 'https' &&
      !(url.scheme == 'http' && permissions.contains('network:http'))) {
    return false;
  }
  if (url.userInfo.isNotEmpty || url.host.isEmpty) return false;
  final host = url.host.toLowerCase();
  return permissions.where((p) => p.startsWith('network:')).any((permission) {
    final domain = permission.substring(8).toLowerCase();
    return host == domain ||
        (domain.startsWith('*.') &&
            host.endsWith(domain.substring(1)) &&
            host.length > domain.length - 1);
  });
}
