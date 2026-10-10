import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../live/guest_camera.dart';
import '../live/rtmp_input_service.dart';
import '../ndi/ndi_input.dart';
import 'theme.dart';

/// Larix Broadcaster's "Grove" link: scanning it adds the connection in
/// the app (https://softvelum.com/larix/grove/).
String larixGroveLink(String rtmpUrl, String name) => 'larix://set/v1?${[
      'conn[][url]=${Uri.encodeComponent(rtmpUrl)}',
      'conn[][name]=${Uri.encodeComponent(name)}',
      'conn[][overwrite]=on',
    ].join('&')}';

Widget _copyRow(BuildContext context, String label, String value, {Key? key}) => Row(key: key, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: ObsColors.textDim, fontSize: 12)),
          SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
        ]),
      ),
      IconButton(
        tooltip: 'Copy',
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$label copied')));
        },
      ),
    ]);

/// Properties of a "Phone / Encoder (RTMP)" source.
class RtmpInputSettings extends StatefulWidget {
  const RtmpInputSettings({super.key, required this.source});

  final Source source;

  @override
  State<RtmpInputSettings> createState() => _RtmpInputSettingsState();
}

class _RtmpInputSettingsState extends State<RtmpInputSettings> {
  late final _key = TextEditingController(text: widget.source.settings['streamKey'] as String? ?? '');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.of(context).liveInputs.rtmp.refreshAddresses();
    });
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final service = scope.liveInputs.rtmp;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final key = (widget.source.settings['streamKey'] as String? ?? '').trim();
        final server = service.serverUrl;
        final full = '$server/$key';
        final feed = service.feed(widget.source.id);
        final (status, color) = switch (feed?.state) {
          null => ('Shown on Program or Preview to start receiving', ObsColors.textDim),
          RtmpInputState.waiting => (feed!.message ?? 'Waiting for the phone to start streaming…', ObsColors.textDim),
          RtmpInputState.live => (
              'Receiving from ${feed!.from ?? 'phone'}'
                  '${feed.width > 0 ? ' · ${feed.width}x${feed.height}' : ''}'
                  ' · ${feed.kbps.toStringAsFixed(0)} kbps'
                  '${feed.hasAudio ? ' · with sound' : ''}'
                  '${feed.message != null ? '\n${feed.message}' : ''}',
              ObsColors.ok
            ),
          RtmpInputState.error => (feed!.message ?? 'Error', ObsColors.live),
        };
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(status, key: const ValueKey('rtmp-in-status'), style: TextStyle(color: color)),
          if (service.serverError != null)
            Text(service.serverError!, style: const TextStyle(color: ObsColors.live)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('rtmp-in-key'),
            controller: _key,
            decoration: const InputDecoration(
              labelText: 'Stream key',
              helperText: 'Each phone needs its own key (letters and numbers)',
            ),
            onSubmitted: (v) => scope.studio.updateSourceSettings(
                widget.source.id, {'streamKey': v.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '')}),
          ),
          const SizedBox(height: 12),
          _copyRow(context, 'Server', server, key: const ValueKey('rtmp-in-server')),
          _copyRow(context, 'Full address', full),
          if (service.addresses.length > 1)
            Text('Other addresses of this tablet: ${service.addresses.skip(1).join(', ')}',
                style: const TextStyle(color: ObsColors.textDim, fontSize: 12)),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(6),
              child: QrImageView(
                key: const ValueKey('rtmp-in-qr'),
                data: larixGroveLink(full, 'OBSpad ${widget.source.name}'),
                size: 132,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Scan with the phone\'s camera to add this connection to Larix Broadcaster (free, Android and '
                'iPhone). Then tap the record button in Larix.\n\n'
                'Prism Live, OBS, vMix, GoPro, ATEM Mini or another OBSpad: use Custom RTMP with the Server and '
                'Stream key above.\n\n'
                'Set video to H.264 and audio to AAC. Both devices must be on the same Wi-Fi or network.',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ]),
        ]);
      },
    );
  }
}

/// Properties of an NDI® Source.
class NdiInputSettings extends StatefulWidget {
  const NdiInputSettings({super.key, required this.source});

  final Source source;

  @override
  State<NdiInputSettings> createState() => _NdiInputSettingsState();
}

class _NdiInputSettingsState extends State<NdiInputSettings> {
  List<String>? _found;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  Future<void> _search() async {
    final service = AppScope.of(context).liveInputs.ndi;
    if (!service.available) return;
    setState(() => _searching = true);
    final list = await service.discover();
    if (!mounted) return;
    setState(() {
      _found = list;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final service = scope.liveInputs.ndi;
    final s = widget.source.settings;
    final current = s['ndiName'] as String? ?? '';
    void set(String k, Object v) => scope.studio.updateSourceSettings(widget.source.id, {k: v});

    if (!service.available) {
      return Text(
        '${service.unavailableReason ?? 'NDI isn\'t available in this build.'}\n\n'
        'NDI input uses the same NDI® runtime as NDI output. See ndi.video.',
        key: const ValueKey('ndi-in-unavailable'),
        style: const TextStyle(color: ObsColors.warn),
      );
    }
    final names = {...?_found, if (current.isNotEmpty) current}.toList()..sort();
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final feed = service.feed(widget.source.id);
        final status = switch (feed?.state) {
          null => current.isEmpty ? 'Pick a source' : 'Shown on Program or Preview to start receiving',
          NdiReceiverState.searching => 'Looking for $current…',
          NdiReceiverState.connected =>
            'Receiving${feed!.width > 0 ? ' · ${feed.width}x${feed.height} · ${feed.fps.toStringAsFixed(0)} fps' : ''}',
          NdiReceiverState.lost => feed!.message ?? 'The sender stopped',
          NdiReceiverState.error => feed!.message ?? 'Error',
        };
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(status,
              key: const ValueKey('ndi-in-status'),
              style: TextStyle(
                  color: feed?.state == NdiReceiverState.connected ? ObsColors.ok : ObsColors.textDim)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('ndi-in-name-${names.length}'),
                initialValue: current.isEmpty ? null : current,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'NDI source'),
                hint: Text(_searching ? 'Searching the network…' : 'No NDI sources found'),
                items: [for (final n in names) DropdownMenuItem(value: n, child: Text(n, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => v == null ? null : set('ndiName', v),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const ValueKey('ndi-in-search'),
              tooltip: 'Search again',
              icon: _searching
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              onPressed: _searching ? null : _search,
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Low bandwidth'),
            subtitle: const Text('NDI\'s preview stream: less Wi-Fi and battery, lower picture quality'),
            value: s['lowBandwidth'] as bool? ?? false,
            onChanged: (v) => set('lowBandwidth', v),
          ),
          const Text(
            'Senders on the same network: vMix, OBS with DistroAV, PTZ cameras, NDI HX Camera on a phone, '
            'or another OBSpad with NDI output on.',
            style: TextStyle(color: ObsColors.textDim, fontSize: 13),
          ),
        ]);
      },
    );
  }
}

/// The guest's link and QR code, on a Guest Camera (Browser) source.
class GuestCameraPanel extends StatelessWidget {
  const GuestCameraPanel({super.key, required this.source});

  final Source source;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final room = source.settings['guestRoom'] as String? ?? '';
    final link = GuestCamera.pushUrl(room);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Guest camera', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(6),
            child: QrImageView(key: const ValueKey('guest-qr'), data: link, size: 140),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'The guest scans this with their phone camera (or opens the link), allows the camera, and taps '
              'Start. Their picture appears here a few seconds later. No app or account needed; works on '
              'Android and iPhone over the internet.\n\n'
              'Their sound isn\'t included. For a phone with sound, use a Phone / Encoder (RTMP) source.',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        _copyRow(context, 'Guest link', link, key: const ValueKey('guest-link')),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('guest-new-link'),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('New link (the old one stops working)'),
            onPressed: () => studio.updateSourceSettings(source.id, GuestCamera.sourceSettings(GuestCamera.newRoom())),
          ),
        ),
        const Divider(),
      ]),
    );
  }
}
