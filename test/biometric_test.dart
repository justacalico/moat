import 'package:flutter_test/flutter_test.dart';
import 'package:moat/services/biometric.dart';

void main() {
  test('LocalAuthGate degrades gracefully without a platform', () async {
    final gate = LocalAuthGate();
    // Missing plugin handlers resolve to false instead of crashing.
    expect(await gate.isAvailable, isFalse);
    expect(await gate.authenticate('test'), isFalse);
  });
}
