import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the SDK keeps the session between runs of the app. The default is
/// the platform's secure store; pass another one to `Murkio.initialize` to
/// keep it elsewhere (or [MurkioMemoryStorage] in tests).
abstract class MurkioStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// Keeps everything in memory: the session ends with the process.
class MurkioMemoryStorage implements MurkioStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// The Keychain on iOS and macOS and preferences encrypted with a Keystore
/// key on Android. On iOS the item is only readable after the first unlock of
/// the device and never leaves it (no iCloud sync, no backup to another
/// phone).
class MurkioSecureStorage implements MurkioStorage {
  MurkioSecureStorage([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
            mOptions: MacOsOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
