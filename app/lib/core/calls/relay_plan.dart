/// A mesh participant's direct links, as its presence reports them.
class LinkReport {
  const LinkReport({this.links = const {}, this.failed = const {}});

  /// Participants with a connected direct link.
  final Set<String> links;

  /// Participants the direct link to failed.
  final Set<String> failed;

  bool sameAs(LinkReport other) =>
      links.length == other.links.length &&
      failed.length == other.failed.length &&
      links.containsAll(other.links) &&
      failed.containsAll(other.failed);
}

/// [origin]'s media forwarded to [target] by a relay member.
typedef RelayJob = ({String origin, String target});

/// The relay links [me] must serve, given everyone's [reports] (its own
/// included). Every participant computes the same plan from the same
/// reports, so the relay needs no extra coordination.
Set<RelayJob> relayJobs(String me, Map<String, LinkReport> reports) {
  final jobs = <RelayJob>{};
  final people = reports.keys.toList()..sort();
  for (final (i, a) in people.indexed) {
    for (final b in people.skip(i + 1)) {
      if (relayFor(a, b, reports) != me) continue;
      jobs
        ..add((origin: a, target: b))
        ..add((origin: b, target: a));
    }
  }
  return jobs;
}

/// Who relays between [a] and [b], or null when they need no relay or
/// nobody can. Rendezvous hashing: the candidate with the highest hash of
/// pair and candidate wins, so pairs spread over members and keep their
/// relay when someone else joins.
String? relayFor(String a, String b, Map<String, LinkReport> reports) {
  final ra = reports[a];
  final rb = reports[b];
  if (ra == null || rb == null) return null;
  if (!ra.failed.contains(b) && !rb.failed.contains(a)) return null;
  final pair = a.compareTo(b) < 0 ? '$a$b' : '$b$a';
  String? best;
  var bestScore = -1;
  for (final MapEntry(key: c, value: report) in reports.entries) {
    if (c == a || c == b) continue;
    if (!report.links.contains(a) || !report.links.contains(b)) continue;
    final score = fnv1a('$pair$c');
    if (score > bestScore || (score == bestScore && c.compareTo(best!) < 0)) {
      best = c;
      bestScore = score;
    }
  }
  return best;
}

/// 32-bit FNV-1a; String.hashCode differs between the VM and the web. The
/// prime (2^24 + 0x193) is applied in parts so no product passes 2^53,
/// where web numbers lose precision.
int fnv1a(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    final x = (hash ^ unit) % 0x100000000;
    hash = ((x % 0x100) * 0x1000000 + x * 0x193) % 0x100000000;
  }
  return hash;
}

/// How long the dialer waits before redialing a link that failed
/// [failures] times in a row.
Duration redialDelay(int failures) => switch (failures) {
  <= 1 => Duration.zero,
  _ => Duration(seconds: (5 << (failures - 2).clamp(0, 4)).clamp(5, 60)),
};

/// [sdp] with no way to reach this end, for tests that force a direct link
/// to fail. The c= and m= lines name a default address too.
String withoutCandidates(String sdp) => sdp
    .split('\r\n')
    .where((line) => !line.startsWith('a=candidate:'))
    .map(
      (line) => line
          .replaceFirst(RegExp(r'^c=IN IP4 \S+'), 'c=IN IP4 0.0.0.0')
          .replaceFirstMapped(RegExp(r'^m=(\w+) \d+ '), (m) => 'm=${m[1]} 9 '),
    )
    .join('\r\n');
