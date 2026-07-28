import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/matrix/display_names.dart';

void main() {
  test('computer-style Matrix localparts have a readable fallback', () {
    expect(humanizeMatrixLocalpart('alex_smith'), 'Alex Smith');
    expect(humanizeMatrixLocalpart('mary-jane'), 'Mary Jane');
  });

  test('an explicitly selected display name is preserved', () {
    expect(
      readableMatrixProfileName(
        userId: '@alex_smith:example.test',
        displayName: 'Alex Smith',
      ),
      'Alex Smith',
    );
  });

  test('a display name copied from the localpart is humanized', () {
    expect(
      readableMatrixProfileName(
        userId: '@alex_smith:example.test',
        displayName: 'alex_smith',
      ),
      'Alex Smith',
    );
  });
}
