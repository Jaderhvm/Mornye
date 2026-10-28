import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/extension_audio_source.dart';
import 'package:mornye/services/extension_audio_proxy.dart';
import 'package:mornye/services/extension_playback_service.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/blowfish.dart';
import 'package:pointycastle/block/modes/cbc.dart';

void main() {
  final transformJson = <String, dynamic>{
    'algorithm': 'blowfish-cbc',
    'key_hex': '00' * 8,
    'iv_hex': '00' * 8,
    'segment_size': 2048,
    'transform_every': 3,
    'transform_offset': 0,
  };
  test('CBC decoding agrees with a published Blowfish test vector', () {
    final transform = AudioBlockTransform.fromJson({
      ...transformJson,
      'segment_size': 8,
    });
    expect(
      transform.decode(
        Uint8List.fromList([0x4e, 0xf9, 0x97, 0x45, 0x61, 0x98, 0xdd, 0x78]),
        0,
      ),
      List.filled(8, 0),
    );
  });
  test(
    'encrypted proxy seek aligns the upstream range and trims decoded audio',
    () async {
      final plain = Uint8List.fromList(List.generate(10000, (i) => i % 251));
      final encrypted = Uint8List.fromList(plain);
      for (var start = 0; start + 2048 <= plain.length; start += 6144) {
        final cipher = CBCBlockCipher(BlowfishEngine())
          ..init(
            true,
            ParametersWithIV(KeyParameter(Uint8List(8)), Uint8List(8)),
          );
        for (var i = 0; i < 2048; i += 8) {
          cipher.processBlock(plain, start + i, encrypted, start + i);
        }
      }
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = ExtensionAudioProxy(allowPrivateAddressesForTesting: true);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.close();
        await upstream.close(force: true);
      });
      upstream.listen((request) async {
        final range = AudioByteRange.parse(request.headers.value('range'))!;
        expect(range.start, 6144);
        expect(range.end, 10239);
        final end = range.end!.clamp(0, plain.length - 1);
        request.response.statusCode = 206;
        request.response.headers.set(
          'Content-Range',
          'bytes ${range.start}-$end/${plain.length}',
        );
        request.response.contentLength = end - range.start + 1;
        for (var i = range.start; i <= end; i += 97) {
          request.response.add(
            encrypted.sublist(i, (i + 97).clamp(0, end + 1)),
          );
        }
        await request.response.close();
      });
      final url = await proxy.open(
        () async => ExtensionAudioSource.fromJson({
          'success': true,
          'url': 'http://127.0.0.1:${upstream.port}/audio',
          'transform': transformJson,
        }),
        ['network:127.0.0.1', 'network:http'],
      );
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('range', 'bytes=6201-9999');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(response.headers.value('content-range'), 'bytes 6201-9999/10000');
      expect(await response.expand((x) => x).toList(), plain.sublist(6201));
    },
  );
  test(
    'stream segments survive arbitrary transport boundaries and partial EOF',
    () async {
      final plain = Uint8List.fromList(
        List.generate(2048 * 7 + 15, (i) => i % 251),
      );
      final encrypted = Uint8List.fromList(plain);
      for (var start = 0; start + 2048 <= plain.length; start += 2048 * 3) {
        final cipher = CBCBlockCipher(BlowfishEngine())
          ..init(
            true,
            ParametersWithIV(KeyParameter(Uint8List(8)), Uint8List(8)),
          );
        for (var i = 0; i < 2048; i += 8) {
          cipher.processBlock(plain, start + i, encrypted, start + i);
        }
      }
      final transform = AudioBlockTransform.fromJson(transformJson);
      final input = Stream<List<int>>.fromIterable([
        for (var i = 0; i < encrypted.length; i += 113)
          encrypted.sublist(i, (i + 113).clamp(0, encrypted.length)),
      ]);
      expect(
        await transform.decodeStream(input, 0).expand((x) => x).toList(),
        plain,
      );
      expect(
        transform.decode(encrypted.sublist(3 * 2048, 4 * 2048), 3),
        plain.sublist(3 * 2048, 4 * 2048),
      );
    },
  );
  test('range alignment includes full independent blocks', () {
    final range = AudioByteRange.parse('bytes=2050-6300')!;
    expect(range.alignedStart(2048), 2048);
    expect(range.alignedEnd(2048), 8191);
    for (final invalid in [
      'bytes=-100',
      'bytes=4-2',
      'bytes=0-1,3-5',
      'garbage',
    ]) {
      expect(() => AudioByteRange.parse(invalid), throwsFormatException);
    }
  });
  test('URLs obey plugin host and HTTP permissions', () {
    expect(
      audioHostAllowed(Uri.parse('https://a.dzcdn.net/x'), [
        'network:*.dzcdn.net',
      ]),
      true,
    );
    expect(
      audioHostAllowed(Uri.parse('https://dzcdn.net.evil.test/x'), [
        'network:*.dzcdn.net',
      ]),
      false,
    );
    expect(
      audioHostAllowed(Uri.parse('http://cdn.test/x'), ['network:cdn.test']),
      false,
    );
    expect(
      audioHostAllowed(Uri.parse('https://u:p@cdn.test/x'), [
        'network:cdn.test',
      ]),
      false,
    );
    expect(
      () => ExtensionAudioSource.fromJson({
        'success': true,
        'url': 'https://cdn.test/x',
        'headers': {'Range': 'bytes=1-'},
      }),
      throwsFormatException,
    );
  });
  test('queue identities are stable and contain no resolved URL or key', () {
    final identity = ExtensionPlaybackService.identity(
      'provider.test',
      'track/12',
    );
    final media = PlayableMedia(
      id: 'track',
      source: identity,
      title: 'Test',
      artist: 'Test',
    );
    expect(media.isNetwork, true);
    expect(Uri.parse(identity).pathSegments, ['provider.test', 'track/12']);
    expect(PlayableMedia.fromJson(media.toJson())!.source, identity);
  });
  test(
    'proxy starts audio before upstream EOF and handles HEAD, seek, expiry',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = ExtensionAudioProxy(
        allowPrivateAddressesForTesting: true,
        onErrorForTesting: (e) => fail('Proxy error: $e'),
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await proxy.close();
        await upstream.close(force: true);
      });
      final data = List.generate(9000, (i) => i % 251);
      final gate = Completer<void>();
      final firstRequest = Completer<void>();
      var calls = 0;
      upstream.listen((request) async {
        try {
          if (request.uri.query == 'expired') {
            request.response.statusCode = 403;
            await request.response.close();
            return;
          }
          final range = AudioByteRange.parse(request.headers.value('range'))!;
          final end = (range.end ?? data.length - 1).clamp(0, data.length - 1);
          request.response.statusCode = 206;
          request.response.headers.set(
            'Content-Range',
            'bytes ${range.start}-$end/${data.length}',
          );
          request.response.bufferOutput = false;
          request.response.contentLength = end - range.start + 1;
          final chunk = data.sublist(range.start, end + 1);
          if (request.uri.path == '/slow') {
            request.response.add(chunk.take(100).toList());
            await request.response.flush();
            if (!firstRequest.isCompleted) firstRequest.complete();
            await gate.future;
            request.response.add(chunk.skip(100).toList());
          } else {
            request.response.add(chunk);
          }
          await request.response.close();
        } catch (_) {}
      });
      final url = await proxy.open(() async {
        calls++;
        return ExtensionAudioSource.fromJson({
          'success': true,
          'url':
              'http://127.0.0.1:${upstream.port}/slow?${calls == 1 ? 'expired' : 'fresh'}',
        });
      }, ['network:127.0.0.1', 'network:http']);
      final response = await (await client.getUrl(Uri.parse(url))).close();
      final iterator = StreamIterator(response);
      expect(
        await iterator.moveNext().timeout(const Duration(seconds: 3)),
        true,
      );
      expect(iterator.current, data.take(100).toList());
      expect(
        gate.isCompleted,
        false,
        reason: 'audio must arrive before the full file',
      );
      gate.complete();
      final received = [...iterator.current];
      while (await iterator.moveNext()) {
        received.addAll(iterator.current);
      }
      expect(received, data);
      expect(calls, 2);
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('range', 'bytes=2050-6300');
      final partial = await request.close();
      expect(partial.statusCode, 206);
      expect(partial.headers.value('content-range'), 'bytes 2050-6300/9000');
      expect(await partial.expand((x) => x).toList(), data.sublist(2050, 6301));
      final head = await client.headUrl(Uri.parse(url));
      final metadata = await head.close();
      expect(metadata.contentLength, 9000);
      expect(await metadata.toList(), isEmpty);
    },
  );
}
