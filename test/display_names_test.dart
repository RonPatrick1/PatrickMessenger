import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/matrix/display_names.dart';

void main() {
  test('computer-style Matrix localparts have a readable fallback', () {
    expect(humanizeMatrixLocalpart('ron_patrick'), 'Ron Patrick');
    expect(humanizeMatrixLocalpart('mary-jane'), 'Mary Jane');
  });

  test('an explicitly selected display name is preserved', () {
    expect(
      readableMatrixProfileName(
        userId: '@ron_patrick:example.test',
        displayName: 'Ron Patrick',
      ),
      'Ron Patrick',
    );
  });

  test('a display name copied from the localpart is humanized', () {
    expect(
      readableMatrixProfileName(
        userId: '@ron_patrick:example.test',
        displayName: 'ron_patrick',
      ),
      'Ron Patrick',
    );
  });
}
