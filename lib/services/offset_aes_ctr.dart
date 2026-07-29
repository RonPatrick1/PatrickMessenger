import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const _blockSize = 16;

/// Decodes a Matrix encrypted-file `key`/`iv` string, which may be base64 or
/// base64url and may be missing its padding. Mirrors the `matrix` package's
/// own (unexported) `base64decodeUnpadded(base64.normalize(s))` two-step
/// exactly, so the same on-wire values decode to the same bytes.
Uint8List decodeUnpaddedBase64(String value) {
  final normalized = base64.normalize(value);
  final needEquals = (4 - (normalized.length % 4)) % 4;
  return base64.decode(normalized + ('=' * needEquals));
}

/// Decrypts an arbitrary byte range of a Matrix encrypted attachment without
/// decrypting anything before [start].
///
/// Matrix encrypted attachments use AES-256-CTR with the full 16-byte [iv]
/// as the initial counter block (not a random-half-plus-counter split —
/// confirmed by reading the `matrix` package's own `encryptFile()`). Since
/// CTR is a stream cipher, the counter for any 16-byte block can be computed
/// independently of every block before it: treat the IV as a big-endian
/// 128-bit integer and add the block index.
Uint8List decryptRange({
  required Uint8List ciphertext,
  int ciphertextOffset = 0,
  required int start,
  required int end, // inclusive
  required Uint8List key,
  required Uint8List iv,
}) {
  final alignedStart = start - (start % _blockSize);
  final counter = counterForAesCtrOffset(iv, alignedStart);

  final length = end - alignedStart + 1;
  final output = Uint8List(length);
  final cipher = SICStreamCipher(AESEngine())
    ..init(false, ParametersWithIV<KeyParameter>(KeyParameter(key), counter));
  final inputOffset = alignedStart - ciphertextOffset;
  if (inputOffset < 0 || inputOffset + length > ciphertext.length) {
    throw RangeError('Ciphertext does not contain the requested byte range.');
  }
  cipher.processBytes(ciphertext, inputOffset, length, output, 0);

  return Uint8List.sublistView(output, start - alignedStart);
}

/// Returns the AES-CTR counter block for an encrypted-file byte offset.
/// [byteOffset] must be aligned to the 16-byte AES block size.
Uint8List counterForAesCtrOffset(Uint8List iv, int byteOffset) {
  if (byteOffset < 0 || byteOffset % _blockSize != 0) {
    throw ArgumentError.value(
      byteOffset,
      'byteOffset',
      'must be 16-byte aligned',
    );
  }
  final blockIndex = byteOffset ~/ _blockSize;
  if (blockIndex == 0) return iv;
  final base = BigInt.parse(
    iv.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    radix: 16,
  );
  final modulus = BigInt.one << (_blockSize * 8);
  final counter = (base + BigInt.from(blockIndex)) % modulus;
  final hex = counter.toRadixString(16).padLeft(_blockSize * 2, '0');
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
