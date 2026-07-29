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
  required int start,
  required int end, // inclusive
  required Uint8List key,
  required Uint8List iv,
}) {
  final alignedStart = start - (start % _blockSize);
  final blockIndex = alignedStart ~/ _blockSize;
  final counter = _counterForBlock(iv, blockIndex);

  final length = end - alignedStart + 1;
  final output = Uint8List(length);
  final cipher = SICStreamCipher(AESEngine())
    ..init(false, ParametersWithIV<KeyParameter>(KeyParameter(key), counter));
  cipher.processBytes(ciphertext, alignedStart, length, output, 0);

  return Uint8List.sublistView(output, start - alignedStart);
}

Uint8List _counterForBlock(Uint8List iv, int blockIndex) {
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
