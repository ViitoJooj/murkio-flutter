import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:murkio_identity/murkio_identity.dart';
import 'package:murkio_identity/src/crypto.dart';

import 'support.dart';

/// A clock the test moves by hand.
class Clock {
  DateTime time = DateTime(2030, 1, 1, 12);

  DateTime call() => time;

  void advance(Duration by) => time = time.add(by);
}

void main() {
  late Clock clock;
  late MurkioMemoryStorage storage;
  final key = 'murkio.${fnv1a32('pk_test')}.session';

  setUp(() {
    clock = Clock();
    storage = MurkioMemoryStorage();
  });

  Future<Murkio> start(FakeApi api, {MurkioStorage? on}) =>
      startMurkio(api, storage: on ?? storage, now: clock.call);

  Future<MurkioSession> signIn(
    Murkio murkio, {
    bool keepLogged = true,
    int expiresIn = 900,
    String id = 'session-1',
  }) => murkio.sessionManager.setSession(
    TokenPair.fromJson(
      tokens(expiresIn: expiresIn, sessionId: id, now: clock.time),
    ),
    keepLogged: keepLogged,
  );

  test('stores one record named after the publishable key', () async {
    final murkio = await start(FakeApi());
    final session = await signIn(murkio);

    final record = jsonDecode(storage.values[key]!) as Map<String, dynamic>;
    expect(record.keys.toSet(), {
      'accessToken',
      'refreshToken',
      'expiresAt',
      'sessionId',
      'ephemeral',
    });
    expect(record['refreshToken'], session.refreshToken);
    expect(record['ephemeral'], isFalse);
    expect(
      record['expiresAt'],
      clock.time.add(const Duration(seconds: 900)).millisecondsSinceEpoch,
    );
    expect(murkio.isSignedIn, isTrue);
    expect(session.userId, 'user-1');
    expect(session.roles, ['user']);
  });

  test('getToken returns the current token while it is fresh', () async {
    final api = FakeApi();
    final murkio = await start(api);
    final session = await signIn(murkio);

    clock.advance(const Duration(seconds: 869));
    expect(await murkio.getToken(), session.accessToken);
    expect(api.calls, isEmpty);
  });

  test('getToken refreshes a token about to expire and keeps the choice of '
      'keep me signed in', () async {
    final api = FakeApi({
      'POST /v1/token/refresh': (_) => Answer.data(tokens(now: clock.time)),
    });
    final murkio = await start(api);
    final first = await signIn(murkio, keepLogged: false);

    clock.advance(const Duration(seconds: 880));
    final token = await murkio.getToken();

    expect(api.calls.single.body, {'refresh_token': first.refreshToken});
    expect(token, isNot(first.accessToken));
    expect(murkio.currentSession!.ephemeral, isTrue);
    expect(
      (jsonDecode(storage.values[key]!) as Map)['refreshToken'],
      murkio.currentSession!.refreshToken,
    );
  });

  test('callers that ask at the same time share one refresh', () async {
    final gate = Completer<void>();
    final api = FakeApi({
      'POST /v1/token/refresh': (_) async {
        await gate.future;
        return Answer.data(tokens(now: clock.time));
      },
    });
    final murkio = await start(api);
    await signIn(murkio);
    clock.advance(const Duration(seconds: 890));

    final pending = [murkio.getToken(), murkio.getToken(), murkio.getToken()];
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    final results = await Future.wait(pending);

    expect(api.to('/v1/token/refresh'), hasLength(1));
    expect(results.toSet(), hasLength(1));
  });

  for (final code in ['rsb-02', 'rsb-03', 'rsb-05']) {
    test('$code on refresh ends the session', () async {
      final api = FakeApi({
        'POST /v1/token/refresh': (_) => Answer.error(401, code),
      });
      final murkio = await start(api);
      await signIn(murkio);
      final changes = <MurkioSession?>[];
      murkio.session.addListener(() => changes.add(murkio.currentSession));
      clock.advance(const Duration(seconds: 890));

      expect(await murkio.getToken(), isNull);
      expect(murkio.isSignedIn, isFalse);
      expect(storage.values, isEmpty);
      expect(changes, [null]);
    });
  }

  test('a network error keeps the session and is reported', () async {
    final api = FakeApi({
      'POST /v1/token/refresh': (_) => throw Exception('offline'),
    });
    final murkio = await start(api);
    final session = await signIn(murkio);
    clock.advance(const Duration(seconds: 890));

    await expectLater(
      murkio.getToken(),
      throwsA(isA<MurkioException>().having((e) => e.code, 'code', 'network')),
    );
    expect(murkio.currentSession, session);
    expect(storage.values, isNotEmpty);

    await murkio.sessionManager.refreshIfDue();
    expect(murkio.currentSession, session);
  });

  test('another error on refresh keeps the session too', () async {
    final api = FakeApi({
      'POST /v1/token/refresh': (_) => Answer.error(429, 'rsb-01'),
    });
    final murkio = await start(api);
    await signIn(murkio);
    clock.advance(const Duration(seconds: 890));

    await expectLater(murkio.getToken(), throwsA(isA<MurkioException>()));
    expect(murkio.isSignedIn, isTrue);
  });

  test('a kept session is restored by the next run of the app', () async {
    final first = await start(FakeApi());
    final session = await signIn(first, id: 'kept-session');

    final api = FakeApi();
    final second = await start(api);
    expect(second.currentSession, session);
    expect(api.calls, isEmpty);
  });

  test(
    'an ephemeral session left by a previous run is logged out and deleted',
    () async {
      storage.values[key] = jsonEncode({
        'accessToken': 'old-access',
        'refreshToken': 'old-refresh',
        'expiresAt': clock.time
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
        'sessionId': 'session-of-a-previous-run',
        'ephemeral': true,
      });
      final api = FakeApi({'POST /v1/logout': (_) => const Answer(204)});

      final murkio = await start(api);
      await Future<void>.delayed(Duration.zero);

      expect(murkio.isSignedIn, isFalse);
      expect(storage.values, isEmpty);
      expect(api.calls.single.path, '/v1/logout');
      expect(api.calls.single.body, {'refresh_token': 'old-refresh'});
    },
  );

  test('an ephemeral session of this run survives a second client', () async {
    final first = await start(FakeApi());
    final session = await signIn(first, keepLogged: false, id: 'this-run');

    final api = FakeApi();
    final second = await start(api);
    expect(second.currentSession, session);
    expect(api.calls, isEmpty);
  });

  test('a record that cannot be read means nobody is signed in', () async {
    storage.values[key] = '{not json';
    expect((await start(FakeApi())).isSignedIn, isFalse);

    storage.values[key] = jsonEncode({'accessToken': 'only-this'});
    expect((await start(FakeApi())).isSignedIn, isFalse);

    final broken = _BrokenStorage();
    final murkio = await start(FakeApi(), on: broken);
    expect(murkio.isSignedIn, isFalse);
    await signIn(murkio);
    expect(murkio.isSignedIn, isTrue, reason: 'works for this run of the app');
  });

  test('signing out deletes the record before calling the API', () async {
    late bool storedDuringLogout;
    final api = FakeApi({
      'POST /v1/logout': (_) {
        storedDuringLogout = storage.values.isNotEmpty;
        return Answer.error(500, 'bss-00');
      },
    });
    final murkio = await start(api);
    final session = await signIn(murkio);

    await murkio.signOut();

    expect(storedDuringLogout, isFalse);
    expect(murkio.isSignedIn, isFalse);
    expect(api.calls.single.body, {'refresh_token': session.refreshToken});
  });

  test(
    'signing out during a refresh does not bring the session back',
    () async {
      final gate = Completer<void>();
      final renewed = tokens(now: clock.time);
      final api = FakeApi({
        'POST /v1/token/refresh': (_) async {
          await gate.future;
          return Answer.data(renewed);
        },
        'POST /v1/logout': (_) => const Answer(204),
      });
      final murkio = await start(api);
      await signIn(murkio);
      clock.advance(const Duration(seconds: 890));

      final refreshing = murkio.getToken();
      await Future<void>.delayed(Duration.zero);
      await murkio.signOut();
      gate.complete();

      expect(await refreshing, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(murkio.isSignedIn, isFalse);
      expect(storage.values, isEmpty);
      expect(
        api.to('/v1/logout').map((c) => (c.body as Map)['refresh_token']),
        contains(renewed['refresh_token']),
      );
    },
  );

  test(
    'a token renewed elsewhere is adopted instead of refreshed again',
    () async {
      final api = FakeApi();
      final murkio = await start(api);
      final session = await signIn(murkio);
      clock.advance(const Duration(seconds: 890));

      // Another isolate of the app already used the refresh token.
      final renewed = MurkioSession(
        accessToken: 'renewed-access',
        refreshToken: 'renewed-refresh',
        expiresAt: clock.time.add(const Duration(minutes: 15)),
        sessionId: session.sessionId,
        ephemeral: false,
      );
      storage.values[key] = jsonEncode(renewed.toJson());

      expect(await murkio.getToken(), 'renewed-access');
      expect(api.calls, isEmpty);
    },
  );

  test('refreshIfDue only calls the API inside the margin', () async {
    final api = FakeApi({
      'POST /v1/token/refresh': (_) => Answer.data(tokens(now: clock.time)),
    });
    final murkio = await start(api);
    await signIn(murkio);

    clock.advance(const Duration(seconds: 800));
    await murkio.sessionManager.refreshIfDue();
    expect(api.calls, isEmpty);

    clock.advance(const Duration(seconds: 20));
    await murkio.sessionManager.refreshIfDue();
    expect(api.calls, hasLength(1));
  });

  test(
    'a restored session that is about to expire is renewed on start',
    () async {
      final first = await start(FakeApi());
      await signIn(first, id: 'old-but-kept');
      clock.advance(const Duration(minutes: 20));

      final api = FakeApi({
        'POST /v1/token/refresh': (_) =>
            Answer.data(tokens(now: clock.time, sessionId: 'old-but-kept')),
      });
      final second = await start(api);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(api.calls, hasLength(1));
      expect(second.currentSession!.expiresAt.isAfter(clock.time), isTrue);
    },
  );
}

class _BrokenStorage implements MurkioStorage {
  @override
  Future<String?> read(String key) => throw StateError('locked');

  @override
  Future<void> write(String key, String value) => throw StateError('locked');

  @override
  Future<void> delete(String key) => throw StateError('locked');
}
