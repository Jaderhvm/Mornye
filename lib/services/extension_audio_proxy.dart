import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'extension_audio_source.dart';

typedef AudioSourceResolver = Future<ExtensionAudioSource> Function();

/// Loopback only; bounded streaming memory; no music files or URL/key logs.
/// Plugin network permissions are checked at every redirect and connection.
class ExtensionAudioProxy {
  ExtensionAudioProxy({
    this.allowPrivateAddressesForTesting = false,
    this.onErrorForTesting,
  });
  final bool allowPrivateAddressesForTesting;
  final void Function(Object)? onErrorForTesting;
  HttpServer? _server;
  Future<HttpServer>? _starting;
  final Map<String, _AudioEntry> _entries = {};
  final Set<HttpClient> _clients = {};

  Future<String> open(
    AudioSourceResolver resolver,
    List<String> permissions,
  ) async {
    final source = await resolver();
    if (!audioHostAllowed(source.url, permissions)) {
      throw StateError('Audio host is outside extension permissions.');
    }
    final server = _server ??= await (_starting ??=
        HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((server) {
          server.listen((request) => unawaited(_serve(request)));
          return server;
        }));
    // Expire inactive handles; a long-lived current stream remains referenced
    // by its serving request. Queue entries store extension identities instead.
    _entries.removeWhere(
      (_, e) => DateTime.now().difference(e.lastUsed).inMinutes > 30,
    );
    if (_entries.length >= 64) _entries.remove(_entries.keys.first);
    final random = Random.secure();
    final token = base64Url
        .encode(List.generate(24, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    _entries[token] = _AudioEntry(resolver, permissions, source);
    return 'http://127.0.0.1:${server.port}/$token';
  }

  Future<void> _serve(HttpRequest incoming) async {
    HttpClient? client;
    try {
      final token = incoming.uri.path.replaceFirst('/', '');
      final entry = _entries[token];
      if (entry == null ||
          incoming.connectionInfo?.remoteAddress.isLoopback != true) {
        incoming.response.statusCode = 404;
        await incoming.response.close();
        return;
      }
      if (!{'GET', 'HEAD'}.contains(incoming.method)) {
        incoming.response.statusCode = 405;
        await incoming.response.close();
        return;
      }
      final range = AudioByteRange.parse(
        incoming.headers.value(HttpHeaders.rangeHeader),
      );
      entry.lastUsed = DateTime.now();
      client = HttpClient()
        ..autoUncompress = false
        ..connectionTimeout = const Duration(seconds: 15)
        ..findProxy = ((_) => 'DIRECT');
      _clients.add(client);
      client.connectionFactory = (uri, _, _) async {
        if (!audioHostAllowed(uri, entry.permissions)) {
          throw const HttpException('Audio host not permitted');
        }
        final addresses = await InternetAddress.lookup(uri.host);
        final address = addresses.firstWhere(
          (a) => allowPrivateAddressesForTesting || _public(a),
          orElse: () =>
              throw const HttpException('Audio address not permitted'),
        );
        return Socket.startConnect(address, uri.port);
      };
      var source = entry.source;
      HttpClientResponse? remote;
      var alignedStart = 0;
      for (var attempt = 0; attempt < 2; attempt++) {
        final block = source.transform?.segmentSize ?? 1;
        alignedStart = range?.alignedStart(block) ?? 0;
        final alignedEnd = range?.alignedEnd(block);
        var uri = source.url;
        for (var redirect = 0; redirect < 6; redirect++) {
          if (!audioHostAllowed(uri, entry.permissions)) {
            throw const HttpException('Audio redirect not permitted');
          }
          final request = await client.getUrl(uri);
          request.followRedirects = false;
          // Do not forward sensitive credentials to a different origin.
          source.headers.forEach((key, value) {
            if (uri.origin == source.url.origin ||
                !{
                  'authorization',
                  'cookie',
                  'proxy-authorization',
                }.contains(key.toLowerCase())) {
              request.headers.set(key, value);
            }
          });
          request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
          request.headers.set(
            HttpHeaders.rangeHeader,
            'bytes=$alignedStart-${alignedEnd ?? ''}',
          );
          remote = await request.close().timeout(const Duration(seconds: 20));
          if (!{301, 302, 303, 307, 308}.contains(remote.statusCode)) break;
          final location = remote.headers.value(HttpHeaders.locationHeader);
          await remote.drain<void>();
          if (location == null) {
            throw const HttpException('Invalid audio redirect');
          }
          uri = uri.resolve(location);
          remote = null;
        }
        if (remote == null) {
          throw const HttpException('Too many audio redirects');
        }
        if ((remote.statusCode == 401 || remote.statusCode == 403) &&
            attempt == 0) {
          await remote.drain<void>();
          source = await entry.resolver();
          entry.source = source;
          continue;
        }
        break;
      }
      if (remote == null || !{200, 206}.contains(remote.statusCode)) {
        throw const HttpException('Audio source unavailable');
      }
      final cr = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+)$',
      ).firstMatch(remote.headers.value(HttpHeaders.contentRangeHeader) ?? '');
      final actualStart = cr == null ? 0 : int.parse(cr[1]!);
      final total = cr == null ? remote.contentLength : int.parse(cr[3]!);
      if (total <= 0 || actualStart != alignedStart) {
        throw const HttpException('Audio server does not support this range');
      }
      final start = range?.start ?? 0;
      final end = (range?.end ?? total - 1).clamp(0, total - 1);
      if (start >= total) {
        incoming.response.statusCode = 416;
        incoming.response.headers.set('Content-Range', 'bytes */$total');
        await incoming.response.close();
        return;
      }
      incoming.response.statusCode = range == null ? 200 : 206;
      incoming.response.headers.set('Accept-Ranges', 'bytes');
      incoming.response.headers.set('Cache-Control', 'no-store');
      incoming.response.headers.set('Content-Type', source.mimeType);
      if (range != null) {
        incoming.response.headers.set(
          'Content-Range',
          'bytes $start-$end/$total',
        );
      }
      incoming.response.bufferOutput = false;
      incoming.response.contentLength = end - start + 1;
      if (incoming.method == 'HEAD') {
        await incoming.response.close();
        return;
      }
      Stream<List<int>> bytes = remote.timeout(const Duration(seconds: 20));
      if (source.transform != null) {
        bytes = source.transform!.decodeStream(bytes, alignedStart);
      }
      var skip = start - alignedStart, left = end - start + 1;
      await for (final chunk in bytes) {
        if (skip >= chunk.length) {
          skip -= chunk.length;
          continue;
        }
        final count = (chunk.length - skip).clamp(0, left);
        incoming.response.add(chunk.sublist(skip, skip + count));
        skip = 0;
        left -= count;
        await incoming.response.flush();
        if (left == 0) break;
      }
      await incoming.response.close();
    } on FormatException {
      try {
        incoming.response.statusCode = 416;
        await incoming.response.close();
      } catch (_) {}
    } catch (error) {
      onErrorForTesting?.call(error);
      // No source URLs, headers or keys enter logs or error responses.
      try {
        incoming.response.statusCode = 502;
        await incoming.response.close();
      } catch (_) {
        // A disconnected native player may have already closed the response.
      }
    } finally {
      if (client != null) {
        _clients.remove(client);
        client.close(force: true);
      }
    }
  }

  static bool _public(InternetAddress a) {
    if (a.isLoopback || a.isLinkLocal || a.isMulticast) return false;
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4) {
      return !(b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          b[0] >= 224 ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127));
    }
    // Global unicast only, including no IPv4-mapped loopback/private addresses.
    return b[0] & 0xe0 == 0x20;
  }

  Future<void> close() async {
    _entries.clear();
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
    _starting = null;
  }
}

class _AudioEntry {
  _AudioEntry(this.resolver, this.permissions, this.source);
  final AudioSourceResolver resolver;
  final List<String> permissions;
  ExtensionAudioSource source;
  DateTime lastUsed = DateTime.now();
}
