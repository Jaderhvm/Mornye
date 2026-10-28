import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/extension_playback_service.dart';
import 'package:mornye/services/playable_media.dart';

/// True means the tap was handled (including an error); never silently download
/// a full file when the user intended streaming.
Future<bool> playExtensionIfAvailable(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  if (track.isCollection || track.source == null) return false;
  final extension = ref
      .read(extensionProvider)
      .extensions
      .where((e) => e.id == track.source && e.enabled)
      .firstOrNull;
  final capability = extension?.capabilities['streaming'];
  if (capability is! Map ||
      capability['version'] != 1 ||
      capability['resolveAction'] is! String) {
    return false;
  }
  try {
    await ref
        .read(musicPlayerControllerProvider)
        .playSingle(
          PlayableMedia(
            id: '${extension!.id}:${track.id}',
            source: ExtensionPlaybackService.identity(extension.id, track.id),
            title: track.name,
            artist: track.artistName,
            album: track.albumName,
            artUri: track.coverUrl,
            duration: track.duration > 0
                ? Duration(seconds: track.duration)
                : null,
            explicit: track.isExplicit,
          ),
        );
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.extensionStreamingPlaybackFailed)),
      );
    }
  }
  return true;
}
