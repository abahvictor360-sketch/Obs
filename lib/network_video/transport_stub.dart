const bool supported = false;

Future<bool> httpGet(String url) async => false;

Future<Stream<List<int>>> openHttpStream(String url, void Function(void Function()) onCancel) async =>
    throw UnsupportedError('Network video works in the Android and iPad apps');
