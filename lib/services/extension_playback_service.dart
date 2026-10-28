import 'extension_audio_proxy.dart';
import 'extension_audio_source.dart';
import 'platform_bridge.dart';

/// Resolves stable extension queue identities only when a track is loaded.
/// Uses the existing generic action bridge and the plugin's normal session.
class ExtensionPlaybackService {
  static final instance = ExtensionPlaybackService();
  final _proxy = ExtensionAudioProxy();
  static String identity(String extensionId, String trackId) => Uri(
    scheme: 'extension-audio',
    host: '',
    pathSegments: [extensionId, trackId],
  ).toString();
  Future<String> resolve(String identity) async {
    final uri = Uri.parse(identity);
    if (uri.scheme != 'extension-audio' || uri.pathSegments.length != 2) {
      throw const FormatException('Invalid extension playback identity');
    }
    final id = uri.pathSegments[0], track = uri.pathSegments[1];
    final installed = await PlatformBridge.getInstalledExtensions();
    final extension = installed
        .where((e) => e['id'] == id && e['enabled'] == true)
        .firstOrNull;
    final capabilities = extension?['capabilities'];
    final streaming = capabilities is Map ? capabilities['streaming'] : null;
    if (streaming is! Map ||
        streaming['version'] != 1 ||
        streaming['resolveAction'] is! String) {
      throw StateError('The enabled extension does not support streaming.');
    }
    final action = streaming['resolveAction'] as String;
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$').hasMatch(action)) {
      throw StateError('Invalid playback action');
    }
    final permissions = (extension!['permissions'] as List? ?? [])
        .cast<String>();
    return _proxy.open(() async {
      // Recheck enabled state/permissions on token refresh; do not let an old
      // handle keep calling a removed or disabled extension.
      final current = await PlatformBridge.getInstalledExtensions();
      final enabled = current
          .where((e) => e['id'] == id && e['enabled'] == true)
          .firstOrNull;
      if (enabled == null ||
          !(enabled['permissions'] as List? ?? []).toSet().containsAll(
            permissions,
          )) {
        throw StateError('Extension is disabled or its permissions changed.');
      }
      final result = await PlatformBridge.invokeExtensionAction(
        id,
        action,
        input: {'track_id': track},
      );
      return ExtensionAudioSource.fromJson(result);
    }, permissions);
  }

  Future<void> close() => _proxy.close();
}
