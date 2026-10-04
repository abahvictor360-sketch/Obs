import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../core/studio_controller.dart';
import 'dock_layout.dart';
import 'docks.dart';
import 'theme.dart';

extension BrowserDocks on StudioController {
  BrowserDockConfig addBrowserDock(String title, String url) {
    final d = BrowserDockConfig(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      title: title.trim().isEmpty ? 'Browser' : title.trim(),
      url: BrowserDockConfig.normalizeUrl(url),
    );
    updateSettings((s) => s.browserDocks.add(d));
    return d;
  }

  void updateBrowserDock(String id, {String? title, String? url}) => updateSettings((s) {
        for (final d in s.browserDocks.where((d) => d.id == id)) {
          if (title != null && title.trim().isNotEmpty) d.title = title.trim();
          if (url != null) d.url = BrowserDockConfig.normalizeUrl(url);
        }
      });

  void removeBrowserDock(String id) => updateSettings((s) {
        s.browserDocks.removeWhere((d) => d.id == id);
        s.hiddenDocks.remove('browser-$id');
        s.dockWeights.remove('browser-$id');
      });
}

/// A web page in a dock: live chat, a stream dashboard, a rundown.
class BrowserDockView extends StatefulWidget {
  const BrowserDockView({super.key, required this.config, this.showTitle = true});

  final BrowserDockConfig config;
  final bool showTitle;

  @override
  State<BrowserDockView> createState() => _BrowserDockViewState();
}

class _BrowserDockViewState extends State<BrowserDockView> {
  InAppWebViewController? _web;
  double _progress = 1;

  /// Only the Android and iPad apps have a WebView (not desktop test runs).
  static bool get _hasWebView => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void didUpdateWidget(BrowserDockView old) {
    super.didUpdateWidget(old);
    if (old.config.url != widget.config.url) {
      _web?.loadUrl(urlRequest: URLRequest(url: WebUri(widget.config.url)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    return Dock(
      title: c.title,
      showTitle: widget.showTitle,
      toolbar: [
        IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back, size: 18),
          onPressed: () => _web?.goBack(),
        ),
        IconButton(
          key: ValueKey('browser-dock-reload-${c.id}'),
          tooltip: 'Reload',
          icon: const Icon(Icons.refresh, size: 18),
          onPressed: () => _web?.reload(),
        ),
        IconButton(
          tooltip: 'Edit',
          icon: const Icon(Icons.edit_outlined, size: 18),
          onPressed: () => showBrowserDocksDialog(context),
        ),
      ],
      child: Stack(children: [
        Positioned.fill(
          child: _hasWebView
              ? InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(c.url)),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    supportZoom: true,
                    isInspectable: kDebugMode,
                  ),
                  onWebViewCreated: (w) => _web = w,
                  onProgressChanged: (_, p) => setState(() => _progress = p / 100),
                )
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(c.url, textAlign: TextAlign.center, style: const TextStyle(color: ObsColors.textDim)),
                  ),
                ),
        ),
        if (_progress < 1)
          Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(value: _progress, minHeight: 2)),
      ]),
    );
  }
}

/// Docks › Custom Browser Docks…: name + URL per dock, like OBS.
Future<void> showBrowserDocksDialog(BuildContext context) {
  final studio = AppScope.of(context).studio;
  final name = TextEditingController();
  final url = TextEditingController();
  // URL edits to existing docks, applied on Enter or when the dialog closes
  // (not on every keystroke: that would reload the page each time).
  final pendingUrls = <String, String>{};
  void commitUrls() {
    pendingUrls.forEach((id, u) => studio.updateBrowserDock(id, url: u));
    pendingUrls.clear();
  }

  return showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: studio,
      builder: (context, _) {
        final docks = studio.settings.browserDocks;
        void add() {
          if (url.text.trim().isEmpty) return;
          final d = studio.addBrowserDock(name.text, url.text);
          studio.setDockVisible(d.dockId, true);
          name.clear();
          url.clear();
        }

        return AlertDialog(
          key: const ValueKey('browser-docks-dialog'),
          title: const Text('Custom Browser Docks'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text(
                  'Show any web page as a dock — live chat, a stream dashboard, a rundown. '
                  'Show, hide and resize it like the other docks.',
                  style: TextStyle(color: ObsColors.textDim, fontSize: 13),
                ),
                const SizedBox(height: 12),
                for (final d in docks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          key: ValueKey('browser-dock-name-${d.id}'),
                          initialValue: d.title,
                          decoration: const InputDecoration(labelText: 'Dock Name', isDense: true),
                          onFieldSubmitted: (v) => studio.updateBrowserDock(d.id, title: v),
                          onChanged: (v) => studio.updateBrowserDock(d.id, title: v),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 4,
                        child: TextFormField(
                          initialValue: d.url,
                          decoration: const InputDecoration(labelText: 'URL', isDense: true),
                          keyboardType: TextInputType.url,
                          onChanged: (v) => pendingUrls[d.id] = v,
                          onFieldSubmitted: (v) {
                            pendingUrls.remove(d.id);
                            studio.updateBrowserDock(d.id, url: v);
                          },
                        ),
                      ),
                      IconButton(
                        key: ValueKey('browser-dock-remove-${d.id}'),
                        tooltip: 'Remove',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => studio.removeBrowserDock(d.id),
                      ),
                    ]),
                  ),
                const Divider(),
                Row(children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      key: const ValueKey('browser-dock-new-name'),
                      controller: name,
                      decoration: const InputDecoration(labelText: 'Dock Name', hintText: 'Chat', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 4,
                    child: TextField(
                      key: const ValueKey('browser-dock-new-url'),
                      controller: url,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                          labelText: 'URL', hintText: 'https://www.youtube.com/live_chat?v=…', isDense: true),
                      onSubmitted: (_) => add(),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('browser-dock-add'),
                    tooltip: 'Add dock',
                    icon: const Icon(Icons.add_circle_outline, color: ObsColors.accent),
                    onPressed: add,
                  ),
                ]),
              ]),
            ),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
        );
      },
    ),
  ).whenComplete(commitUrls);
}
