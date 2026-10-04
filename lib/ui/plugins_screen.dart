import 'dart:convert';
import 'dart:collection';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../app_scope.dart';
import '../plugins/plugin_manager.dart';
import '../plugins/plugin_manifest.dart';
import '../plugins/plugin_runtime_js.dart';
import 'dialogs.dart';
import 'ndi_settings.dart';
import 'theme.dart';

void openPlugins(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PluginsScreen()));
}

class PluginsScreen extends StatelessWidget {
  const PluginsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final plugins = AppScope.of(context).plugins;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Plugins'),
          backgroundColor: ObsColors.header,
          bottom: const TabBar(tabs: [Tab(text: 'Installed'), Tab(text: 'Get plugins')]),
        ),
        body: ListenableBuilder(
          listenable: plugins,
          builder: (context, _) => const TabBarView(children: [_InstalledTab(), _GetPluginsTab()]),
        ),
      ),
    );
  }
}

class _InstalledTab extends StatelessWidget {
  const _InstalledTab();

  @override
  Widget build(BuildContext context) {
    final plugins = AppScope.of(context).plugins;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _Header('Built in'),
        for (final b in kBuiltinPlugins)
          Card(
            color: ObsColors.panelAlt,
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.settings_input_antenna),
                  title: Text(b.name),
                  subtitle: Text(b.description),
                  value: plugins.isEnabled(b.id),
                  onChanged: (v) => plugins.setEnabled(b.id, v),
                ),
                if (b.id == ndiBuiltin.id && plugins.isEnabled(b.id)) const NdiSettingsPanel(),
              ],
            ),
          ),
        const SizedBox(height: 16),
        const _Header('Installed from GitHub or files'),
        if (!plugins.supported)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Script plugins run in the Android and iPad apps.', style: TextStyle(color: ObsColors.textDim)),
          )
        else if (plugins.plugins.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('No plugins yet. Open "Get plugins" to install one from GitHub.',
                style: TextStyle(color: ObsColors.textDim)),
          ),
        for (final p in plugins.plugins) _PluginCard(plugin: p),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Text(text, style: const TextStyle(color: ObsColors.accent, fontWeight: FontWeight.bold)),
      );
}

class _PluginCard extends StatefulWidget {
  const _PluginCard({required this.plugin});
  final PluginEntry plugin;

  @override
  State<_PluginCard> createState() => _PluginCardState();
}

class _PluginCardState extends State<_PluginCard> {
  bool _checking = false;

  Future<void> _checkUpdate() async {
    final plugins = AppScope.of(context).plugins;
    setState(() => _checking = true);
    try {
      final pending = await plugins.checkUpdate(widget.plugin);
      if (!mounted) return;
      if (pending == null) {
        _snack('${widget.plugin.manifest.name} is up to date');
      } else {
        await confirmAndInstall(context, pending);
      }
    } catch (e) {
      _snack('Update check failed: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final plugins = AppScope.of(context).plugins;
    final p = widget.plugin;
    final m = p.manifest;
    return Card(
      color: ObsColors.panelAlt,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.extension_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Text('${m.name}  ${m.version}', style: Theme.of(context).textTheme.titleMedium),
              ),
              Switch(value: plugins.isEnabled(m.id), onChanged: (v) => plugins.setEnabled(m.id, v)),
            ]),
            if (m.description.isNotEmpty) Text(m.description),
            const SizedBox(height: 4),
            Text(
              [if (m.author.isNotEmpty) 'by ${m.author}', p.fromGitHub ? p.source.replaceFirst('https://', '') : p.source]
                  .join(' · '),
              style: const TextStyle(color: ObsColors.textDim, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final s in m.sources) Chip(avatar: const Icon(Icons.layers_outlined, size: 16), label: Text(s.name)),
              for (final d in m.docks) Chip(avatar: const Icon(Icons.web_asset, size: 16), label: Text(d.name)),
              for (final o in m.overlays) Chip(avatar: const Icon(Icons.web, size: 16), label: Text(o.name)),
              if (m.luts.isNotEmpty)
                Chip(avatar: const Icon(Icons.palette_outlined, size: 16), label: Text('${m.luts.length} LUTs')),
              if (m.media.isNotEmpty)
                Chip(avatar: const Icon(Icons.perm_media_outlined, size: 16), label: Text('${m.media.length} media')),
              for (final perm in m.permissions)
                Chip(
                  avatar: Icon(perm == PluginPermission.network ? Icons.public : Icons.tune, size: 16),
                  label: Text(perm.name),
                ),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final d in m.docks)
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.open_in_new),
                  label: Text('Open ${d.name}'),
                  onPressed: plugins.isEnabled(m.id) ? () => openPluginDock(context, p, d) : null,
                ),
              if (p.fromGitHub)
                OutlinedButton.icon(
                  icon: _checking
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.system_update_alt),
                  label: const Text('Check for update'),
                  onPressed: _checking ? null : _checkUpdate,
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.article_outlined),
                label: const Text('Log'),
                onPressed: () => _showLog(context, p),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove'),
                style: OutlinedButton.styleFrom(foregroundColor: ObsColors.live),
                onPressed: () async {
                  if (await confirm(context,
                      title: 'Remove plugin',
                      message: 'Remove "${m.name}"? Sources that use it will show a placeholder.')) {
                    await plugins.uninstall(m.id);
                  }
                },
              ),
            ]),
          ],
        ),
      ),
    );
  }

  void _showLog(BuildContext context, PluginEntry p) {
    final lines = AppScope.of(context).plugins.logs[p.manifest.id] ?? const [];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${p.manifest.name} log'),
        content: SizedBox(
          width: 640,
          height: 400,
          child: lines.isEmpty
              ? const Center(child: Text('Nothing logged yet'))
              : ListView(
                  children: [
                    for (final l in lines.reversed)
                      SelectableText(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ],
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }
}

class _GetPluginsTab extends StatefulWidget {
  const _GetPluginsTab();

  @override
  State<_GetPluginsTab> createState() => _GetPluginsTabState();
}

class _GetPluginsTabState extends State<_GetPluginsTab> {
  final _url = TextEditingController();
  bool _busy = false;
  Future<List<CatalogEntry>>? _catalog;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _run(Future<PendingInstall> Function() fetch) async {
    setState(() => _busy = true);
    try {
      final pending = await fetch();
      if (mounted) await confirmAndInstall(context, pending);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fromFile() async {
    final plugins = AppScope.of(context).plugins;
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (files.isEmpty) return;
    final f = files.single;
    await _run(() async => plugins.readZip(await f.readAsBytes(), f.name));
  }

  @override
  Widget build(BuildContext context) {
    final plugins = AppScope.of(context).plugins;
    if (!plugins.supported) {
      return const Center(child: Text('Script plugins run in the Android and iPad apps.'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _Header('From GitHub'),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _url,
              enabled: !_busy,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Repository',
                hintText: 'owner/repo or https://github.com/owner/repo',
                helperText: 'Any OBS overlay, widget, LUT or stinger repo works, with or without an OBSpad manifest.',
                helperMaxLines: 2,
              ),
              onSubmitted: (_) => _run(() => plugins.fetchFromGitHub(_url.text)),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download),
            label: const Text('Install'),
            onPressed: _busy ? null : () => _run(() => plugins.fetchFromGitHub(_url.text)),
          ),
        ]),
        const SizedBox(height: 24),
        const _Header('From a file'),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.folder_zip_outlined),
            label: const Text('Install from .zip…'),
            onPressed: _busy ? null : _fromFile,
          ),
        ),
        const SizedBox(height: 24),
        Row(children: [
          const Expanded(child: _Header('Plugin catalog')),
          TextButton.icon(
            icon: const Icon(Icons.refresh),
            label: Text(_catalog == null ? 'Load' : 'Refresh'),
            onPressed: () => setState(() => _catalog = plugins.fetchCatalog()),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Catalog address',
            onPressed: () async {
              final url = await promptText(context, title: 'Catalog URL', initial: plugins.catalogUrl, label: 'URL');
              if (url != null) {
                await plugins.setCatalogUrl(url);
                setState(() => _catalog = plugins.fetchCatalog());
              }
            },
          ),
        ]),
        if (_catalog != null)
          FutureBuilder<List<CatalogEntry>>(
            future: _catalog,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
              }
              if (snap.hasError) {
                return Text('Could not load the catalog: ${snap.error}', style: const TextStyle(color: ObsColors.warn));
              }
              final items = snap.data!;
              if (items.isEmpty) return const Text('The catalog is empty.');
              return Column(children: [
                for (final c in items)
                  ListTile(
                    leading: const Icon(Icons.extension_outlined),
                    title: Text(c.name),
                    subtitle: Text([c.description, if (c.author.isNotEmpty) 'by ${c.author}'].join('\n')),
                    isThreeLine: c.description.isNotEmpty && c.author.isNotEmpty,
                    trailing: FilledButton.tonal(
                      onPressed: _busy ? null : () => _run(() => plugins.fetchFromGitHub(c.url)),
                      child: const Text('Install'),
                    ),
                  ),
              ]);
            },
          ),
        const SizedBox(height: 24),
        const Text(
          'A repo or zip without an obspad-plugin.json is converted: web pages become overlays (Add Source › '
          'From plugins) or docks, .cube files appear in Apply LUT, and images and videos in Add Source. '
          'Native OBS plugins (Windows/macOS .dll and C/C++ code) and Lua/Python scripts only run in OBS on a '
          'computer.\n\n'
          'Plugins run in a sandbox: they can draw sources and docks, and only reach the internet or control '
          'the studio if you allow it. Writing your own? See docs/PLUGINS.md in the OBSpad repository.',
          style: TextStyle(color: ObsColors.textDim, fontSize: 13),
        ),
      ],
    );
  }
}

/// Shows what a plugin wants before installing it.
Future<void> confirmAndInstall(BuildContext context, PendingInstall pending) async {
  final plugins = AppScope.of(context).plugins;
  final m = pending.manifest;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(pending.isUpdate ? 'Update ${m.name}?' : 'Install ${m.name}?'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(pending.isUpdate ? '${pending.existing!.manifest.version} → ${m.version}' : 'Version ${m.version}'),
            if (m.author.isNotEmpty) Text('by ${m.author}'),
            Text(pending.source.replaceFirst('https://', ''), style: const TextStyle(color: ObsColors.textDim)),
            if (m.description.isNotEmpty) ...[const SizedBox(height: 8), Text(m.description)],
            const SizedBox(height: 12),
            for (final line in m.contents) Text('Adds ${line[0].toLowerCase()}${line.substring(1)}'),
            if (m.converted) ...[
              const SizedBox(height: 8),
              const Text(
                'This package has no obspad-plugin.json, so OBSpad converted it: web pages become overlays '
                '(Add Source › From plugins) or docks, LUTs appear in Apply LUT, and images and videos in Add Source.',
                style: TextStyle(color: ObsColors.textDim, fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            const Text('This plugin can:', style: TextStyle(fontWeight: FontWeight.bold)),
            const Text('• Draw its sources and docks'),
            for (final p in m.permissions) Text('• ${p.description}', style: const TextStyle(color: ObsColors.warn)),
            const SizedBox(height: 12),
            const Text('Only install plugins from people you trust.', style: TextStyle(color: ObsColors.textDim)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(pending.isUpdate ? 'Update' : 'Install')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    await plugins.install(pending);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${m.name} ${m.version} installed')));
    }
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Install failed: $e')));
  }
}

/// A plugin's dock page (a panel UI), with the same `obstablet` API.
void openPluginDock(BuildContext context, PluginEntry plugin, PluginDock dock) {
  final plugins = AppScope.of(context).plugins;
  final network = plugin.manifest.permissions.contains(PluginPermission.network);
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (context) => Scaffold(
      appBar: AppBar(title: Text('${plugin.manifest.name} · ${dock.name}'), backgroundColor: ObsColors.header),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri.uri(Uri.file('${plugin.directory}/${dock.page}'))),
        initialUserScripts: UnmodifiableListView([
          UserScript(source: kPluginRuntimeJs, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
          if (!network)
            UserScript(
              // Same network lockdown as the sandbox page.
              source: '''(function(){var m=document.createElement('meta');m.httpEquiv='Content-Security-Policy';
m.content="connect-src 'none'";(document.head||document.documentElement).prepend(m);})();''',
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            ),
        ]),
        initialSettings: InAppWebViewSettings(
          allowFileAccess: true,
          allowFileAccessFromFileURLs: true,
          allowUniversalAccessFromFileURLs: false,
          allowingReadAccessTo: WebUri.uri(Uri.directory(plugin.directory)),
          transparentBackground: true,
        ),
        onWebViewCreated: (c) => c.addJavaScriptHandler(
          handlerName: 'obst',
          callback: (args) async {
            final m = jsonDecode('${args.first}') as Map<String, dynamic>;
            if (m['t'] == 'log' || m['t'] == 'error') {
              plugins.log(plugin.manifest.id, '[${dock.name}] ${m['msg']}');
              return null;
            }
            if (m['t'] != 'control') return null;
            try {
              return jsonEncode({'value': await plugins.control(plugin, '${m['op']}', m)});
            } catch (e) {
              return jsonEncode({'error': '$e'});
            }
          },
        ),
      ),
    ),
  ));
}
