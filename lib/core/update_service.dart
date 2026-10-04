import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A newer build published on GitHub Releases (tag `build-<n>`).
class UpdateInfo {
  const UpdateInfo({required this.build, required this.pageUrl, this.apkUrl, this.ipaUrl, this.published});

  final int build;
  final String pageUrl;
  final String? apkUrl;
  final String? ipaUrl;
  final DateTime? published;

  /// What the Download button opens: the APK on Android (the browser
  /// downloads it, then the installer updates the app in place), the release
  /// page elsewhere.
  String downloadUrl(TargetPlatform platform) =>
      (platform == TargetPlatform.android ? apkUrl : null) ?? pageUrl;

  /// Parses GitHub's `releases/latest` response; null if it isn't a build.
  static UpdateInfo? fromRelease(Map<String, dynamic> j) {
    final m = RegExp(r'^build-(\d+)$').firstMatch(j['tag_name'] as String? ?? '');
    if (m == null) return null;
    String? asset(bool Function(String) match) {
      for (final a in (j['assets'] as List? ?? const [])) {
        final name = (a as Map)['name'] as String? ?? '';
        if (match(name)) return a['browser_download_url'] as String?;
      }
      return null;
    }

    return UpdateInfo(
      build: int.parse(m.group(1)!),
      pageUrl: j['html_url'] as String? ?? UpdateService.releasesPage,
      apkUrl: asset((n) => n.endsWith('.apk')),
      ipaUrl: asset((n) => n.endsWith('.ipa')),
      published: DateTime.tryParse(j['published_at'] as String? ?? ''),
    );
  }
}

typedef ReleaseFetcher = Future<Map<String, dynamic>> Function();

/// Checks GitHub Releases for a newer build than the one running: shortly
/// after launch, then every few hours while the app stays open.
class UpdateService extends ChangeNotifier {
  UpdateService({required this.currentBuild, ReleaseFetcher? fetch}) : _fetch = fetch ?? _fetchLatest;

  static const repo = 'abahvictor360-sketch/Obs';
  static const releasesPage = 'https://github.com/$repo/releases/latest';

  /// The app's shared instance; tests swap it out.
  static UpdateService instance = UpdateService(
    currentBuild: int.tryParse(const String.fromEnvironment('OBSPAD_BUILD')),
  );

  /// Null for local (`dev`) builds, which never get update prompts.
  final int? currentBuild;
  final ReleaseFetcher _fetch;

  UpdateInfo? _available;
  int? _dismissedBuild;
  bool _checking = false;
  Timer? _timer;

  /// The newest build, if it's newer than this one.
  UpdateInfo? get available => _available;
  bool get checking => _checking;

  /// Whether to show the update banner (not after "Later" for that build).
  bool get shouldNotify => _available != null && _available!.build != _dismissedBuild;

  void start({Duration firstCheck = const Duration(seconds: 8), Duration every = const Duration(hours: 6)}) {
    if (currentBuild == null || _timer != null) return;
    _timer = Timer(firstCheck, () {
      check();
      _timer = Timer.periodic(every, (_) => check());
    });
  }

  void dismiss() {
    _dismissedBuild = _available?.build;
    notifyListeners();
  }

  /// Returns the newer build, or null if this one is the latest. Throws when
  /// GitHub can't be reached so a manual check can say so.
  Future<UpdateInfo?> check() async {
    _checking = true;
    notifyListeners();
    try {
      final latest = UpdateInfo.fromRelease(await _fetch());
      final cur = currentBuild;
      _available = latest != null && cur != null && latest.build > cur ? latest : null;
      return _available;
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  static Future<Map<String, dynamic>> _fetchLatest() async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await http.getUrl(Uri.parse('https://api.github.com/repos/$repo/releases/latest'));
      req.headers.set(HttpHeaders.userAgentHeader, 'OBSpad');
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw HttpException('GitHub returned ${res.statusCode}');
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      http.close(force: true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
