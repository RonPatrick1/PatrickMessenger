import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/services/offset_aes_ctr.dart';
import 'package:pointycastle/export.dart';

void main() {
  final random = Random(42);
  final key = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
  final iv = Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
  // Deliberately not a multiple of 16 so a trailing partial block is
  // exercised too.
  final plaintext = Uint8List.fromList(
    List.generate(5013, (i) => i % 256),
  );

  late Uint8List ciphertext;

  setUpAll(() {
    final cipher = SICStreamCipher(AESEngine())
      ..init(true, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
    ciphertext = Uint8List(plaintext.length);
    cipher.processBytes(plaintext, 0, plaintext.length, ciphertext, 0);
  });

  void expectRangeMatches(int start, int end) {
    final decrypted = decryptRange(
      ciphertext: ciphertext,
      start: start,
      end: end,
      key: key,
      iv: iv,
    );
    expect(decrypted, equals(plaintext.sublist(start, end + 1)));
  }

  test('16-byte-aligned start', () => expectRangeMatches(32, 63));

  test('mid-block (non-aligned) start', () => expectRangeMatches(40, 100));

  test(
    'spans multiple blocks with an unaligned end',
    () => expectRangeMatches(10, 4000),
  );

  test(
    'single byte at the very end of the buffer',
    () => expectRangeMatches(plaintext.length - 1, plaintext.length - 1),
  );

  test('the very first byte of the buffer', () => expectRangeMatches(0, 0));

  test('the entire buffer in one call', () {
    final decrypted = decryptRange(
      ciphertext: ciphertext,
      start: 0,
      end: plaintext.length - 1,
      key: key,
      iv: iv,
    );
    expect(decrypted, equals(plaintext));
  });
}
