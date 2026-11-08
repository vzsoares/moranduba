import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moranduba/core/calls/sfu_client.dart';
import 'package:moranduba/core/status.dart';
import 'package:ndk/ndk.dart';

StatusProbe _probe(http.Client client) => StatusProbe(
  Ndk(
    NdkConfig(cache: MemCacheManager(), eventVerifier: Bip340EventVerifier()),
  ),
  me: 'a' * 64,
  client: client,
  timeout: const Duration(seconds: 1),
);

void main() {
  test('a file server answering below 500 is up', () async {
    final probe = _probe(MockClient((_) async => http.Response('', 404)));
    final check = await probe.fileServer('https://files.test');
    expect(check.health, isNot(Health.down));
    expect(check.latency, isNotNull);
  });

  test('a file server error shows its status', () async {
    final probe = _probe(MockClient((_) async => http.Response('', 503)));
    final check = await probe.fileServer('https://files.test');
    expect(check.health, Health.down);
    expect(check.detail, 'HTTP 503');
  });

  test('a call server error becomes the detail', () async {
    final probe = _probe(MockClient((_) async => http.Response('', 200)));
    final check = await probe.callServer(
      () async => throw const SfuException('not allowed'),
    );
    expect(check.health, Health.down);
    expect(check.detail, 'not allowed');
  });

  test('a call server that never answers times out', () async {
    final probe = _probe(MockClient((_) async => http.Response('', 200)));
    final check = await probe.callServer(
      () => Future<void>.delayed(const Duration(seconds: 10)),
    );
    expect(check.detail, 'No answer in time');
  });

  test('errors drop their class prefix', () {
    expect(describeError(StateError('No relay accepted')), 'No relay accepted');
    expect(describeError(const SfuException('gone')), 'gone');
  });
}
