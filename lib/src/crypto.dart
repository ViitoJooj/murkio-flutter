import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// fnv1a32 is the short, non-cryptographic hash that names the storage keys
/// of a publishable key. Every Murkio SDK computes the same one (FNV-1a, 32
/// bits, lowercase hex), so the name stays the same across them.
String fnv1a32(String value) {
  const prime = 0x01000193;
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    // Multiplied in two halves: on the web an int is a double, and the full
    // product would lose its low bits.
    final low = (hash & 0xffff) * prime;
    final high = (((hash >>> 16) * prime) & 0xffff) << 16;
    hash = (low + high) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

const String _alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

/// A random string of unreserved URL characters, from the system's secure
/// generator (PKCE verifier and OAuth state).
String randomString(int length, [Random? random]) {
  final source = random ?? Random.secure();
  return String.fromCharCodes(
    Iterable.generate(
      length,
      (_) => _alphabet.codeUnitAt(source.nextInt(_alphabet.length)),
    ),
  );
}

/// S256 code challenge of a PKCE verifier (RFC 7636).
String codeChallenge(String verifier) => base64Url
    .encode(sha256.convert(utf8.encode(verifier)).bytes)
    .replaceAll('=', '');
