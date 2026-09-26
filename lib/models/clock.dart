/// Vector clock used to decide which replica of a note is newer.
///
/// Each device increments its own entry when it edits a note. Comparing two
/// clocks yields [ClockOrder.dominant] when every entry in [a] is >= the
/// matching entry in [b] (and at least one is strictly greater).
enum ClockOrder { equal, dominant, dominated, concurrent }

class Clock {
  Clock._(); // coverage:ignore-line

  static Map<String, int> tick(Map<String, int> clock, String deviceId) {
    final next = Map<String, int>.from(clock);
    next[deviceId] = (next[deviceId] ?? 0) + 1;
    return next;
  }

  static ClockOrder compare(Map<String, int> a, Map<String, int> b) {
    var aGreater = false;
    var bGreater = false;
    for (final key in {...a.keys, ...b.keys}) {
      final av = a[key] ?? 0;
      final bv = b[key] ?? 0;
      if (av > bv) aGreater = true;
      if (bv > av) bGreater = true;
      if (aGreater && bGreater) return ClockOrder.concurrent;
    }
    if (!aGreater && !bGreater) return ClockOrder.equal;
    return aGreater ? ClockOrder.dominant : ClockOrder.dominated;
  }
}
