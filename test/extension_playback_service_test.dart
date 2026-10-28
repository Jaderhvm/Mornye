import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/extension_playback_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'generic action bridge resolves a stable identity without persisting credentials',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'getInstalledExtensions') {
          return jsonEncode([
            {
              'id': 'example.provider',
              'enabled': true,
              'permissions': ['network:cdn.test'],
              'capabilities': {
                'streaming': {'version': 1, 'resolveAction': 'resolvePlayback'},
              },
            },
          ]);
        }
        expect(call.method, 'invokeExtensionAction');
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        expect(arguments['extension_id'], 'example.provider');
        expect(arguments['action'], 'resolvePlayback');
        expect(jsonDecode(arguments['arguments_json'] as String), [
          {'track_id': 'track/12'},
        ]);
        return jsonEncode({
          'success': true,
          'url': 'https://cdn.test/audio?secret=temporary',
        });
      });
      final service = ExtensionPlaybackService();
      addTearDown(service.close);
      final url = await service.resolve(
        ExtensionPlaybackService.identity('example.provider', 'track/12'),
      );
      expect(url, startsWith('http://127.0.0.1:'));
      expect(url, isNot(contains('temporary')));
      expect(
        calls.where((c) => c.method == 'invokeExtensionAction'),
        hasLength(1),
      );
    },
  );
  test('disabled and older extensions are not called or downloaded', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getInstalledExtensions');
      return jsonEncode([
        {'id': 'old', 'enabled': true, 'capabilities': <String, dynamic>{}},
      ]);
    });
    final service = ExtensionPlaybackService();
    addTearDown(service.close);
    await expectLater(
      service.resolve(ExtensionPlaybackService.identity('old', '12')),
      throwsStateError,
    );
    await expectLater(
      service.resolve(ExtensionPlaybackService.identity('disabled', '12')),
      throwsStateError,
    );
  });
}
