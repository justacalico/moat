import 'package:flutter_test/flutter_test.dart';
import 'package:moat/util/format.dart';

void main() {
  test('relativeTime buckets', () {
    final now = DateTime.now();
    expect(relativeTime(now), 'just now');
    expect(relativeTime(now.subtract(const Duration(minutes: 5))), '5m ago');
    expect(relativeTime(now.subtract(const Duration(hours: 3))), '3h ago');
    expect(relativeTime(now.subtract(const Duration(days: 3))), '3d ago');
    expect(relativeTime(DateTime(2020, 1, 1)), isNot(contains('ago')));
  });

  test('fullTime and timeOnly produce strings', () {
    final t = DateTime(2026, 3, 4, 15, 30);
    expect(fullTime(t), contains('Mar'));
    expect(timeOnly(t), contains('15'));
  });

  test('previewLine strips markdown and truncates', () {
    expect(previewLine('# Hello **world**'), 'Hello world');
    expect(previewLine('a' * 200).length, lessThanOrEqualTo(140));
    expect(previewLine('a' * 200), endsWith('…'));
    expect(previewLine('short'), 'short');
  });
}
