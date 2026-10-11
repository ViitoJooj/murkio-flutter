import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:murkio_identity/murkio_identity.dart';
import 'package:murkio_identity/src/crypto.dart';

import 'support.dart';

void main() {
  test('only a publishable key is accepted', () {
    expect(
      () => Murkio(publishableKey: 'sk_live_secret', observeLifecycle: false),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          isNot(contains('sk_live_secret')),
        ),
      ),
    );
    expect(
      () => Murkio(publishableKey: '', observeLifecycle: false),
      throwsArgumentError,
    );
  });

  test('Murkio.instance explains what is missing', () {
    Murkio.reset();
    expect(
      () => Murkio.instance,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Murkio.initialize'),
        ),
      ),
    );
  });

  test('requests carry the key and reach the configured API', () async {
    final api = FakeApi({
      'GET /v1/client': (_) => Answer.data(bootstrapJson()),
    });
    final murkio = await startMurkio(api);
    final bootstrap = await murkio.bootstrap();

    expect(bootstrap.applicationId, 'app-1');
    expect(bootstrap.canvasVersion, 3);
    expect(bootstrap.config.passwordEnabled, isTrue);
    expect(api.calls.single.headers['Authorization'], 'Bearer pk_test');
    expect(murkio.api.apiUrl, 'https://api.example.com');
    expect(murkio.keyHash, fnv1a32('pk_test'));
  });

  test(
    'the bootstrap is kept for a minute, then revalidated by its ETag',
    () async {
      var time = DateTime(2030);
      final api = FakeApi({
        'GET /v1/client':
            (call) =>
                call.headers['If-None-Match'] == 'W/"v1"'
                    ? const Answer(304)
                    : Answer.data(bootstrapJson(), headers: {'etag': 'W/"v1"'}),
      });
      final murkio = await startMurkio(api, now: () => time);

      final first = await murkio.bootstrap();
      expect(identical(await murkio.bootstrap(), first), isTrue);
      expect(api.calls, hasLength(1));

      time = time.add(const Duration(seconds: 61));
      expect(identical(await murkio.bootstrap(), first), isTrue);
      expect(api.calls, hasLength(2));
      expect(api.calls.last.headers['If-None-Match'], 'W/"v1"');

      time = time.add(const Duration(seconds: 30));
      await murkio.bootstrap();
      expect(api.calls, hasLength(2), reason: 'a 304 renews the minute');
    },
  );

  test('concurrent bootstraps share one request', () async {
    final api = FakeApi({
      'GET /v1/client': (_) => Answer.data(bootstrapJson()),
    });
    final murkio = await startMurkio(api);
    await Future.wait([murkio.bootstrap(), murkio.bootstrap()]);
    expect(api.calls, hasLength(1));
  });

  test('a failed revalidation falls back to the last bootstrap', () async {
    var time = DateTime(2030);
    var online = true;
    final api = FakeApi({
      'GET /v1/client':
          (_) =>
              online
                  ? Answer.data(bootstrapJson())
                  : throw Exception('offline'),
    });
    final murkio = await startMurkio(api, now: () => time);
    final first = await murkio.bootstrap();

    online = false;
    time = time.add(const Duration(minutes: 5));
    expect(identical(await murkio.bootstrap(), first), isTrue);
  });

  test('without any bootstrap the error reaches the caller', () async {
    final murkio = await startMurkio(
      FakeApi({'GET /v1/client': (_) => Answer.error(401, 'bss-01')}),
    );
    await expectLater(
      murkio.bootstrap(),
      throwsA(
        isA<MurkioException>()
            .having((e) => e.code, 'code', 'bss-01')
            .having((e) => e.status, 'status', 401)
            .having((e) => e.localized('pt-BR'), 'localized', isNotEmpty),
      ),
    );
  });

  test('the profile is cached per session for a minute', () async {
    var time = DateTime(2030);
    final api = FakeApi({
      'POST /v1/me':
          (_) => Answer.data({
            'id': 'user-1',
            'session_id': 'session-1',
            'email': 'ana@example.com',
            'email_verified': true,
            'roles': ['user', 'admin'],
            'mfa_enabled': false,
            'created_at': '2029-05-01T10:00:00Z',
          }),
    });
    final murkio = await startMurkio(api, now: () => time);
    expect(await murkio.getUser(), isNull);

    final session = await murkio.sessionManager.setSession(
      TokenPair.fromJson(tokens(now: time)),
      keepLogged: true,
    );
    final user = (await murkio.getUser())!;
    expect(user.email, 'ana@example.com');
    expect(user.roles, ['user', 'admin']);
    expect(user.createdAt, DateTime.utc(2029, 5, 1, 10));
    expect(api.calls.single.body, {'access_token': session.accessToken});

    await murkio.getUser();
    expect(api.calls, hasLength(1));

    time = time.add(const Duration(seconds: 61));
    await murkio.getUser();
    expect(api.calls, hasLength(2));

    await murkio.sessionManager.setSession(
      TokenPair.fromJson(tokens(now: time, sessionId: 'session-2')),
      keepLogged: true,
    );
    await murkio.getUser();
    expect(api.calls, hasLength(3), reason: 'another session, another profile');
  });

  test(
    'MurkioHttpClient adds the access token to requests of the app',
    () async {
      final murkio = await startMurkio(FakeApi());
      final seen = <String?>[];
      final client = MurkioHttpClient(
        murkio: murkio,
        inner: MockClient((request) async {
          seen.add(request.headers['Authorization']);
          return http.Response('ok', 200);
        }),
      );

      await client.get(Uri.parse('https://app.example.com/me'));
      final session = await murkio.sessionManager.setSession(
        TokenPair.fromJson(tokens()),
        keepLogged: true,
      );
      await client.get(Uri.parse('https://app.example.com/me'));

      expect(seen, [null, 'Bearer ${session.accessToken}']);
    },
  );

  group('social sign-in', () {
    const redirect = 'https://app.example.com/auth/callback';
    late List<Uri> opened;
    late MurkioMemoryStorage storage;
    late FakeApi api;

    setUp(() {
      opened = [];
      storage = MurkioMemoryStorage();
      api = FakeApi({
        'POST /v1/oauth/google/authorize':
            (_) => Answer.data({
              'authorization_url': 'https://accounts.example.com/o/auth?x=1',
            }),
      });
    });

    Future<Murkio> start({String? redirectUrl = redirect, bool opens = true}) =>
        startMurkio(
          api,
          storage: storage,
          oauthRedirectUrl: redirectUrl,
          openUrl: (url) async {
            opened.add(url);
            return opens;
          },
        );

    Map<String, dynamic> attempt(Murkio murkio) =>
        jsonDecode(storage.values['murkio.${murkio.keyHash}.oauth']!)
            as Map<String, dynamic>;

    test('starts with PKCE and opens the provider', () async {
      final murkio = await start();
      expect(murkio.oauthEnabled, isTrue);
      await murkio.startOAuth('google', keepLogged: true);

      final body = api.calls.single.body as Map<String, dynamic>;
      final stored = attempt(murkio);
      expect(body['redirect_url'], redirect);
      expect(body['code_challenge_method'], 'S256');
      expect(
        body['code_challenge'],
        codeChallenge(stored['verifier'] as String),
      );
      expect(body['state'], stored['state']);
      expect((stored['verifier'] as String).length, 64);
      expect((stored['state'] as String).length, 32);
      expect(stored['keepLogged'], isTrue);
      expect(opened.single.host, 'accounts.example.com');
    });

    test(
      'is refused without a return link, and when the browser cannot open',
      () async {
        final none = await start(redirectUrl: null);
        expect(none.oauthEnabled, isFalse);
        await expectLater(
          none.startOAuth('google', keepLogged: true),
          throwsA(isA<MurkioException>()),
        );
        expect(api.calls, isEmpty);

        final closed = await start(opens: false);
        await expectLater(
          closed.startOAuth('google', keepLogged: true),
          throwsA(isA<MurkioException>()),
        );
        expect(storage.values, isEmpty);
      },
    );

    test('never opens an authorization link that is not https', () async {
      api.routes['POST /v1/oauth/google/authorize'] =
          (_) => Answer.data({'authorization_url': 'intent://evil'});
      final murkio = await start();
      await expectLater(
        murkio.startOAuth('google', keepLogged: true),
        throwsA(isA<MurkioException>()),
      );
      expect(opened, isEmpty);
    });

    test('the return with the code becomes a session', () async {
      api.routes['POST /v1/oauth/token'] = (_) => Answer.data(tokens());
      final murkio = await start();
      await murkio.startOAuth('google', keepLogged: false);
      final stored = attempt(murkio);

      final handled = await murkio.handleRedirect(
        Uri.parse('$redirect?code=oac_1&state=${stored['state']}'),
      );

      expect(handled, isTrue);
      expect(api.calls.last.body, {
        'code': 'oac_1',
        'code_verifier': stored['verifier'],
      });
      expect(murkio.isSignedIn, isTrue);
      expect(murkio.currentSession!.ephemeral, isTrue);
      expect(storage.values.keys, isNot(contains(contains('oauth'))));
    });

    test('a link with another state is not ours', () async {
      final murkio = await start();
      await murkio.startOAuth('google', keepLogged: true);

      expect(
        await murkio.handleRedirect(Uri.parse('$redirect?code=x&state=other')),
        isFalse,
      );
      expect(
        await murkio.handleRedirect(Uri.parse('$redirect?code=x')),
        isFalse,
      );
      expect(
        await murkio.handleRedirect(Uri.parse('https://app.example.com/')),
        isFalse,
      );
      expect(api.calls, hasLength(1));
      expect(storage.values, isNotEmpty, reason: 'the attempt is still open');
    });

    test('an error return reaches the sign-in screen once', () async {
      final murkio = await start();
      await murkio.startOAuth('google', keepLogged: true);
      final flow = FlowController(murkio);
      addTearDown(flow.dispose);

      await murkio.handleRedirect(
        Uri.parse(
          '$redirect?error=access_denied&state=${attempt(murkio)['state']}',
        ),
      );

      expect(flow.state.error?.code, 'oauth.access_denied');
      expect(murkio.takeOAuthError(), isNull);
      expect(murkio.isSignedIn, isFalse);
    });

    test('a 2FA challenge continues on the sign-in screen', () async {
      api.routes['POST /v1/oauth/token'] =
          (_) => Answer.data({
            'mfa': {'token': 'mfa_9', 'enrollment_required': false},
          });
      api.routes['POST /v1/mfa/challenge/verify'] =
          (_) => Answer.data(tokens());
      final murkio = await start();
      await murkio.startOAuth('google', keepLogged: false);
      final flow = FlowController(murkio);
      addTearDown(flow.dispose);

      await murkio.handleRedirect(
        Uri.parse('$redirect?code=oac_2&state=${attempt(murkio)['state']}'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(flow.state.step, isA<MfaStep>());
      await flow.verifyMfa('123456');
      expect(flow.state.step, isA<DoneStep>());
      expect(murkio.currentSession!.ephemeral, isTrue);
    });
  });
}
