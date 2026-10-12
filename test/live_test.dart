import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:murkio_identity/murkio_identity.dart';

// Runs against a real identity API when these are set:
//   MURKIO_LIVE_API, MURKIO_LIVE_PK, MURKIO_LIVE_EMAIL, MURKIO_LIVE_PASSWORD
// (an application with a verified user). Skipped otherwise.
void main() {
  final env = Platform.environment;
  final apiUrl = env['MURKIO_LIVE_API'];
  final key = env['MURKIO_LIVE_PK'];
  final email = env['MURKIO_LIVE_EMAIL'];
  final password = env['MURKIO_LIVE_PASSWORD'];
  final skip = [apiUrl, key, email, password].contains(null)
      ? 'set MURKIO_LIVE_* to run against a real API'
      : null;

  Murkio create(MurkioStorage storage, {DateTime Function()? now}) => Murkio(
    publishableKey: key!,
    apiUrl: apiUrl,
    locale: 'en',
    storage: storage,
    now: now,
    observeLifecycle: false,
  );

  test(
    'bootstrap, login, profile, refresh and logout against the API',
    () async {
      final storage = MurkioMemoryStorage();
      final murkio = create(storage);
      addTearDown(murkio.dispose);
      await murkio.start();

      final bootstrap = await murkio.bootstrap();
      expect(bootstrap.applicationId, isNotEmpty);
      expect(
        pickCanvas(bootstrap.canvasDocument, bootstrap.config).signIn.elements,
        isNotEmpty,
      );

      final flow = FlowController(murkio);
      addTearDown(flow.dispose);
      await flow.login(
        MurkioCredentials(
          email: email!,
          password: 'definitely-wrong',
          keepLogged: true,
        ),
      );
      expect(flow.state.error?.code, 'rsb-00');

      await flow.login(
        MurkioCredentials(
          email: '  ${email.toUpperCase()} ',
          password: password!,
          keepLogged: true,
        ),
      );
      expect(flow.state.error, isNull);
      expect(flow.state.step, isA<DoneStep>());
      final first = murkio.currentSession!;
      expect(first.claims!.sessionId, first.sessionId);

      final user = (await murkio.getUser())!;
      expect(user.email, email);
      expect(user.sessionId, first.sessionId);

      // A second client on the same storage is "the next run of the app", with
      // a clock far enough ahead to make the token due.
      final later = create(
        storage,
        now: () => DateTime.now().add(const Duration(minutes: 20)),
      );
      addTearDown(later.dispose);
      await later.start();
      final tokens = await Future.wait([later.getToken(), later.getToken()]);
      expect(tokens[0], isNotNull);
      expect(tokens[0], tokens[1]);
      expect(tokens[0], isNot(first.accessToken));
      expect(later.currentSession!.sessionId, first.sessionId);
      expect((await later.getUser())!.id, user.id);

      final refreshToken = later.currentSession!.refreshToken;
      await later.signOut();
      expect(later.isSignedIn, isFalse);
      await expectLater(
        later.api.refresh(refreshToken),
        throwsA(
          isA<MurkioException>().having(
            (e) => e.code,
            'code',
            anyOf('rsb-02', 'rsb-03', 'rsb-05'),
          ),
        ),
      );
    },
    skip: skip,
  );
}
