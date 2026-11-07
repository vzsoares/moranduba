import 'host_identity.dart';

export 'host_identity.dart';

/// Browsers cannot run the SFU.
bool get canHostCalls => false;

Future<HostedSfu> startHostedSfu({
  required String dataDir,
  required List<String> relays,
}) => throw UnsupportedError('Hosting calls needs the desktop app');
