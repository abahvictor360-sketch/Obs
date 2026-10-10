import 'media_import.dart';

class CancelToken {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

Future<String?> downloadMedia(Uri url, MediaKind kind,
        {required void Function(double? progress) progress, required CancelToken cancel, String? directory}) async =>
    url.toString(); // web: play from the link
