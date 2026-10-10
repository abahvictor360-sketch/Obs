import 'package:flutter/material.dart';

import 'media_import.dart';
import 'media_link_stub.dart' if (dart.library.io) 'media_link_io.dart' as impl;
import 'theme.dart';

/// Where a pasted link really downloads from, or why it can't be used.
class MediaLink {
  const MediaLink._(this.url, this.problem);

  final Uri? url;
  final String? problem;

  static MediaLink parse(String input) {
    final raw = input.trim();
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
      return const MediaLink._(null, 'Paste a web link (https://…)');
    }
    final host = uri.host.toLowerCase();
    const streaming = ['youtube.com', 'youtu.be', 'facebook.com', 'fb.watch', 'instagram.com', 'tiktok.com', 'vimeo.com'];
    if (streaming.any((h) => host == h || host.endsWith('.$h'))) {
      return const MediaLink._(
        null,
        'Videos on YouTube, Facebook, Instagram, TikTok or Vimeo can\'t be downloaded here. Download your own '
        'video from the site to the tablet, then use Browse files. (Use a Browser source to show a web page.)',
      );
    }
    // Google Drive share links: /file/d/<id>/view or ?id=<id>.
    if (host == 'drive.google.com' || host == 'docs.google.com') {
      final m = RegExp(r'/d/([A-Za-z0-9_-]{10,})').firstMatch(uri.path);
      final id = m?.group(1) ?? uri.queryParameters['id'];
      if (id != null) {
        return MediaLink._(
          Uri.https('drive.usercontent.google.com', '/download', {'id': id, 'export': 'download', 'confirm': 't'}),
          null,
        );
      }
    }
    // Dropbox: ?dl=0 shows a page; dl=1 is the file.
    if (host == 'dropbox.com' || host.endsWith('.dropbox.com')) {
      return MediaLink._(uri.replace(queryParameters: {...uri.queryParameters, 'dl': '1'}), null);
    }
    return MediaLink._(uri, null);
  }
}

/// Asks for a link (Google Drive, Dropbox, OneDrive "download" link, or any
/// direct link to a file), downloads it into the app's storage with a
/// progress bar, and returns the local path.
Future<String?> pickMediaFromLink(BuildContext context, MediaKind kind) async {
  final ctl = TextEditingController();
  final what = kind == MediaKind.image ? 'image' : 'video';
  final url = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('media-link-dialog'),
      title: Text('Add $what from a link'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            key: const ValueKey('media-link-url'),
            controller: ctl,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Link', hintText: 'https://drive.google.com/file/d/…'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          const SizedBox(height: 8),
          const Text(
            'Google Drive and Dropbox share links work (set sharing to "Anyone with the link"), as do direct '
            'links to a file. The file is saved on the tablet, so it plays even without internet later.',
            style: TextStyle(color: ObsColors.textDim, fontSize: 13),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('Download')),
      ],
    ),
  );
  ctl.dispose();
  if (url == null || url.trim().isEmpty || !context.mounted) return null;
  final link = MediaLink.parse(url);
  final messenger = ScaffoldMessenger.of(context);
  if (link.url == null) {
    messenger.showSnackBar(SnackBar(duration: const Duration(seconds: 8), content: Text(link.problem!)));
    return null;
  }
  final progress = ValueNotifier<double?>(null);
  final cancel = impl.CancelToken();
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text('Downloading $what…'),
      content: ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (context, p, _) => Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(value: p),
          const SizedBox(height: 8),
          Text(p == null ? 'Starting…' : '${(p * 100).toStringAsFixed(0)} %'),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancel.cancel();
            Navigator.pop(context);
          },
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  try {
    final path = await impl.downloadMedia(link.url!, kind, progress: (p) => progress.value = p, cancel: cancel);
    if (!cancel.cancelled && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    await dialog;
    return cancel.cancelled ? null : path;
  } catch (e) {
    if (!cancel.cancelled && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    await dialog;
    messenger.showSnackBar(SnackBar(duration: const Duration(seconds: 8), content: Text('$e')));
    return null;
  } finally {
    progress.dispose();
  }
}
