import 'package:intl/intl.dart';

final _dateFmt = DateFormat.yMMMd();
final _timeFmt = DateFormat.Hm();
final _fullFmt = DateFormat.yMMMd().add_Hm();

/// Relative time for list rows: "just now", "5m", "3h", "Mar 12".
String relativeTime(DateTime when) {
  final diff = DateTime.now().difference(when);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return _dateFmt.format(when);
}

String fullTime(DateTime when) => _fullFmt.format(when);

String timeOnly(DateTime when) => _timeFmt.format(when);

/// Turns arbitrary text into a short list preview.
String previewLine(String body, {int max = 140}) {
  final clean = body
      .replaceAll(RegExp(r'[#*`>\-\[\]]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (clean.length <= max) return clean;
  return '${clean.substring(0, max - 1)}…';
}
