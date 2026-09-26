import 'package:flutter_test/flutter_test.dart';
import 'package:moat/util/platform_name.dart';

void main() {
  test('platformDeviceName returns a non-empty name', () {
    expect(platformDeviceName(), isNotEmpty);
  });
}
