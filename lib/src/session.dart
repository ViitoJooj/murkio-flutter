import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'errors.dart';
import 'models.dart';
import 'storage.dart';

/// Refresh this long before the access token expires.
const Duration refreshMargin = Duration(seconds: 90);

const Duration _minimumWait = Duration(seconds: 10);

/// A refresh answered with one of these means the session is over.
const Set<String> _endedCodes = {'rsb-02', 'rsb-03', 'rsb-05'};

/// The signed-in session: the tokens and when the access token expires.
@immutable
class MurkioSession {
  const MurkioSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.sessionId,
    required this.ephemeral,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String sessionId;

  /// "Keep me signed in" was off: the session does not survive the app.
  final bool ephemeral;

  /// The claims of the access token, read without checking its signature.
  AccessClaims? get claims => decodeClaims(accessToken);

  String? get userId => claims?.subject;

  List<String> get roles => claims?.roles ?? const [];

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'sessionId': sessionId,
    'ephemeral': ephemeral,
  };

  static MurkioSession? fromJson(Object? json) {
    if (json is! Map ||
        json['accessToken'] is! String ||
        json['refreshToken'] is! String ||
        json['expiresAt'] is! num ||
        json['sessionId'] is! String) {
      return null;
    }
    return MurkioSession(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (json['expiresAt'] as num).toInt(),
      ),
      sessionId: json['sessionId'] as String,
      ephemeral: json['ephemeral'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MurkioSession &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken &&
      other.sessionId == sessionId &&
      other.ephemeral == ephemeral &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode =>
      Object.hash(accessToken, refreshToken, sessionId, ephemeral, expiresAt);
}

/// SessionManager keeps the user's tokens.
///
/// - One record in the secure storage, named after the publishable key.
/// - Refreshes run one at a time: the refresh token rotates on every use and
///   the API revokes the whole session when a used one shows up again
///   (rsb-03), so concurrent callers share one request, and the record is
///   read again first in case another isolate already renewed it.
/// - "Keep me signed in" off marks the record ephemeral: the next start of
///   the app finds it, logs it out and deletes it.
/// - A network error keeps the session; only the API saying the session is
///   over signs the user out.
class SessionManager {
  SessionManager({
    required ApiClient api,
    required MurkioStorage storage,
    required String keyHash,
    DateTime Function()? now,
    bool Function()? isForeground,
  }) : _api = api,
       _storage = storage,
       _keyHash = keyHash,
       _now = now ?? DateTime.now,
       _isForeground = isForeground ?? (() => true);

  final ApiClient _api;
  final MurkioStorage _storage;
  final String _keyHash;
  final DateTime Function() _now;
  final bool Function() _isForeground;
  final ValueNotifier<MurkioSession?> _state = ValueNotifier(null);
  Future<MurkioSession?>? _inflight;
  Timer? _timer;
  bool _disposed = false;

  /// Sessions stored by this process. An ephemeral record that is not here
  /// was left by a previous run of the app.
  static final Set<String> _alive = {};

  String get _key => 'murkio.$_keyHash.session';

  /// The session, and a notification whenever it changes.
  ValueListenable<MurkioSession?> get listenable => _state;

  MurkioSession? get current => _state.value;

  bool get isSignedIn => current != null;

  /// Restores the session of a previous run and keeps it fresh.
  Future<void> start() async {
    final stored = await _read();
    if (stored != null &&
        stored.ephemeral &&
        !_alive.contains('$_keyHash:${stored.sessionId}')) {
      unawaited(_api.logout(stored.refreshToken).then((_) {}, onError: (_) {}));
      await _delete();
      _set(null);
      return;
    }
    _set(stored);
    if (_isForeground()) unawaited(refreshIfDue());
  }

  Future<MurkioSession> setSession(
    TokenPair tokens, {
    required bool keepLogged,
  }) async {
    final session = MurkioSession(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      expiresAt: _now().add(Duration(seconds: tokens.expiresIn)),
      sessionId: tokens.sessionId,
      ephemeral: !keepLogged,
    );
    _alive.add('$_keyHash:${session.sessionId}');
    _set(session);
    await _write(session);
    return session;
  }

  /// A valid access token, refreshed first when it expires within
  /// [minValidity]. Null when nobody is signed in or the session is over.
  Future<String?> getToken({
    Duration minValidity = const Duration(seconds: 30),
  }) async {
    final session = current;
    if (session == null) return null;
    if (session.expiresAt.difference(_now()) > minValidity) {
      return session.accessToken;
    }
    return (await refresh())?.accessToken;
  }

  /// Renews the tokens, once for every caller that asks at the same time.
  /// Network errors keep the session and throw.
  Future<MurkioSession?> refresh() =>
      _inflight ??= _refresh().whenComplete(() => _inflight = null);

  Future<MurkioSession?> _refresh() async {
    var before = current;
    if (before == null) return null;

    final stored = await _read();
    if (stored != null &&
        stored.sessionId == before.sessionId &&
        stored.refreshToken != before.refreshToken) {
      before = stored;
      _set(stored);
    }
    if (before.expiresAt.difference(_now()) > refreshMargin) return before;

    final TokenPair pair;
    try {
      pair = await _api.refresh(before.refreshToken);
    } on MurkioException catch (error) {
      if (_endedCodes.contains(error.code)) {
        await clear();
        return null;
      }
      rethrow;
    }

    // The user signed out while the request was on its way: the new tokens
    // must not bring the session back.
    final latest = current;
    if (latest == null) {
      unawaited(_api.logout(pair.refreshToken).then((_) {}, onError: (_) {}));
      return null;
    }
    return setSession(pair, keepLogged: !latest.ephemeral);
  }

  /// Renews the tokens when they are about to expire; errors are left for
  /// the next [getToken] to report.
  Future<void> refreshIfDue() async {
    final session = current;
    if (session == null ||
        session.expiresAt.difference(_now()) > refreshMargin) {
      return;
    }
    try {
      await refresh();
    } on MurkioException {
      // Offline: the session stays, and getToken() will try again.
    }
  }

  Future<void> signOut() async {
    final session = current;
    await clear();
    if (session != null) {
      try {
        await _api.logout(session.refreshToken);
      } on MurkioException {
        // The record is gone either way; the API expires the session itself.
      }
    }
  }

  Future<void> clear() async {
    _set(null);
    await _delete();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _state.dispose();
  }

  void _set(MurkioSession? session) {
    if (_disposed) return;
    _state.value = session;
    _schedule(session);
  }

  void _schedule(MurkioSession? session) {
    _timer?.cancel();
    _timer = null;
    if (session == null) return;
    // Never sooner than a few seconds: with a token that lives less than the
    // margin, "refresh when due" would otherwise call the API in a loop.
    final due = session.expiresAt.subtract(refreshMargin).difference(_now());
    _timer = Timer(due < _minimumWait ? _minimumWait : due, () {
      _timer = null;
      if (_isForeground()) unawaited(refreshIfDue());
    });
  }

  Future<MurkioSession?> _read() async {
    try {
      final raw = await _storage.read(_key);
      return raw == null ? null : MurkioSession.fromJson(jsonDecode(raw));
    } catch (_) {
      // A storage that cannot be read only means "no session to restore".
      return null;
    }
  }

  Future<void> _write(MurkioSession session) async {
    try {
      await _storage.write(_key, jsonEncode(session.toJson()));
    } catch (_) {
      // The session still works for this run of the app.
    }
  }

  Future<void> _delete() async {
    try {
      await _storage.delete(_key);
    } catch (_) {
      // Nothing to delete, or nothing we can do about it.
    }
  }
}
