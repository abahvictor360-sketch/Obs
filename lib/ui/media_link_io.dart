import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'media_import.dart';

class CancelToken {
  bool cancelled = false;
  HttpClient? _client;
  void cancel() {
    cancelled = true;
    _client?.close(force: true);
  }
}

/// Downloads [url] into `<documents>/obs_tablet/media/` and returns the path.
Future<String?> downloadMedia(Uri url, MediaKind kind,
    {required void Function(double? progress) progress, required CancelToken cancel, String? directory}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  cancel._client = client;
  File? target;
  try {
    final req = await client.getUrl(url);
    req.headers.set(HttpHeaders.userAgentHeader, 'OBSpad');
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException(res.statusCode == 404 || res.statusCode == 403
          ? 'The link isn\'t shared publicly (error ${res.statusCode}). Share it with "Anyone with the link".'
          : 'The server answered ${res.statusCode}');
    }
    final type = res.headers.contentType;
    if (type != null && type.primaryType == 'text') {
      await res.drain<void>();
      throw const HttpException(
          'That link opens a web page, not a file. Use the file\'s download link, or share it publicly.');
    }
    final name = _fileName(res, url, type, kind);
    final dir = Directory(directory ?? '${(await getApplicationDocumentsDirectory()).path}/obs_tablet/media');
    await dir.create(recursive: true);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var file = File('${dir.path}/$name');
    for (var n = 2; await file.exists(); n++) {
      file = File('${dir.path}/$stem ($n)$ext');
    }
    target = file;
    final total = res.contentLength;
    var got = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in res) {
        if (cancel.cancelled) break;
        sink.add(chunk);
        got += chunk.length;
        progress(total > 0 ? got / total : null);
      }
    } finally {
      await sink.close();
    }
    if (cancel.cancelled) {
      await file.delete().catchError((_) => file);
      return null;
    }
    return file.path;
  } catch (e) {
    if (target != null && await target.exists()) await target.delete().catchError((_) => target!);
    if (cancel.cancelled) return null;
    if (e is SocketException) throw const HttpException('No internet connection');
    rethrow;
  } finally {
    client.close(force: true);
  }
}

String _fileName(HttpClientResponse res, Uri url, ContentType? type, MediaKind kind) {
  String? name;
  final cd = res.headers.value('content-disposition');
  if (cd != null) {
    final m = RegExp(r'''filename\*?=(?:UTF-8'')?"?([^";]+)"?''', caseSensitive: false).firstMatch(cd);
    if (m != null) name = Uri.decodeComponent(m.group(1)!);
  }
  name ??= url.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
  if (name == null || name == 'download' || !name.contains('.')) {
    final ext = switch (type?.subType) {
      'mp4' => 'mp4',
      'quicktime' => 'mov',
      'webm' => 'webm',
      'png' => 'png',
      'jpeg' => 'jpg',
      'gif' => 'gif',
      'webp' => 'webp',
      _ => kind == MediaKind.image ? 'jpg' : 'mp4',
    };
    name = '${name == null || name == 'download' ? 'download' : name}.$ext';
  }
  return name.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
}
