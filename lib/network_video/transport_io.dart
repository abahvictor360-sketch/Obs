import 'dart:async';
import 'dart:convert';
import 'dart:io';

const bool supported = true;

/// GETs [url] and returns the body as a stream. [onCancel] receives a
/// function that aborts the request.
Future<Stream<List<int>>> openHttpStream(String url, void Function(void Function()) onCancel) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..idleTimeout = const Duration(seconds: 10);
  onCancel(() => client.close(force: true));
  final uri = Uri.parse(url);
  final req = await client.getUrl(uri);
  if (uri.userInfo.isNotEmpty) {
    // IP cameras with http://user:pass@host/ URLs.
    req.headers.set(HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode(Uri.decodeComponent(uri.userInfo)))}');
  }
  final res = await req.close().timeout(const Duration(seconds: 8));
  if (res.statusCode == 401) throw const HttpException('The camera needs a username and password');
  if (res.statusCode != 200) throw HttpException('The camera answered HTTP ${res.statusCode}');
  // Treat a stalled stream as a disconnect.
  return res.timeout(const Duration(seconds: 6), onTimeout: (sink) {
    sink.addError(TimeoutException('Stream timed out'));
    sink.close();
  });
}
