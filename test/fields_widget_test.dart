import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:murkio_identity/murkio_identity.dart';

import 'support.dart';
import 'widget_support.dart';

/// A sign-in form made of the standalone widgets, the way an app writes it.
Widget form(
  Murkio murkio, {
  bool keepLogged = false,
  ValueChanged<MurkioSession>? onLogin,
  ValueChanged<MurkioException>? onError,
}) {
  return MurkioIdentityForm(
    murkio: murkio,
    onLogin: onLogin,
    onError: onError,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const MurkioIdentityEmailInput(
          key: ValueKey('email'),
          decoration: InputDecoration(labelText: 'Email'),
        ),
        const MurkioIdentityPasswordInput(
          key: ValueKey('password'),
          decoration: InputDecoration(labelText: 'Password'),
        ),
        if (keepLogged)
          const MurkioIdentityKeepLogged(
            key: ValueKey('keep'),
            label: Text('Stay signed in'),
          ),
        const MurkioIdentityError(key: ValueKey('error')),
        const MurkioIdentityLoginButton(
          key: ValueKey('login'),
          child: Text('Sign in'),
        ),
        const MurkioIdentityRegisterButton(
          key: ValueKey('register'),
          child: Text('Create account'),
        ),
      ],
    ),
  );
}

Future<void> fill(
  WidgetTester tester, {
  String email = ' Ana@Example.com',
  String password = 'S3nha!forte',
}) async {
  await tester.enterText(find.byKey(const ValueKey('email')), email);
  await tester.enterText(find.byKey(const ValueKey('password')), password);
}

Future<void> press(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await settle(tester);
}

void main() {
  testMurkio('the login button signs in with what the inputs hold', (
    tester,
  ) async {
    final api = canvasApi(
      routes: {'POST /v1/login': (_) => Answer.data(tokens())},
    );
    final murkio = await startMurkio(api);
    final logins = <MurkioSession>[];
    await pumpApp(tester, form(murkio, onLogin: logins.add));

    await fill(tester);
    await press(tester, 'login');

    expect(api.to('/v1/login').single.body, {
      'email': 'ana@example.com',
      'password': 'S3nha!forte',
    });
    expect(logins, hasLength(1));
    expect(
      murkio.currentSession!.ephemeral,
      isFalse,
      reason: 'no checkbox in the form: an app keeps the session',
    );
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const ValueKey('password')),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      isEmpty,
    );
  });

  testMurkio('the checkbox decides whether the session is kept', (
    tester,
  ) async {
    final api = canvasApi(
      routes: {'POST /v1/login': (_) => Answer.data(tokens())},
    );
    final murkio = await startMurkio(api);
    await pumpApp(tester, form(murkio, keepLogged: true));

    await fill(tester);
    await press(tester, 'login');
    expect(murkio.currentSession!.ephemeral, isTrue, reason: 'left unchecked');

    await murkio.sessionManager.clear();
    await tester.tap(find.text('Stay signed in'));
    await tester.pump();
    await fill(tester);
    await press(tester, 'login');
    expect(murkio.currentSession!.ephemeral, isFalse);
  });

  testMurkio('buttons are disabled while a request runs, and the error shows', (
    tester,
  ) async {
    final gate = Completer<void>();
    final api = canvasApi(
      routes: {
        'POST /v1/login': (_) async {
          await gate.future;
          return Answer.error(401, 'rsb-00');
        },
      },
    );
    final murkio = await startMurkio(api);
    final errors = <MurkioException>[];
    await pumpApp(tester, form(murkio, onError: errors.add));

    await fill(tester);
    await press(tester, 'login');
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );

    gate.complete();
    await settle(tester);
    expect(find.text(translateError('rsb-00')), findsOneWidget);
    expect(errors.single.code, 'rsb-00');
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testMurkio('signup opens the email code in a dialog and signs in', (
    tester,
  ) async {
    final api = canvasApi(
      routes: {
        'POST /v1/signup': (_) => const Answer(204),
        'POST /v1/email/verification/confirm': (_) => Answer.data(tokens()),
      },
    );
    final murkio = await startMurkio(api);
    final logins = <MurkioSession>[];
    await pumpApp(tester, form(murkio, onLogin: logins.add));

    await fill(tester);
    await press(tester, 'register');
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Confirm your email'), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      ),
      '123456',
    );
    await tester.tap(find.text('Confirm'));
    await settle(tester);

    expect(find.byType(Dialog), findsNothing);
    expect(logins, hasLength(1));
    expect(api.to('/v1/email/verification/confirm').single.body, {
      'email': 'ana@example.com',
      'code': '123456',
      'password': 'S3nha!forte',
    });
  });

  testMurkio('dismissing the dialog goes back to the form', (tester) async {
    final api = canvasApi(
      routes: {'POST /v1/signup': (_) => const Answer(204)},
    );
    final murkio = await startMurkio(api);
    await pumpApp(tester, form(murkio));

    await fill(tester);
    await press(tester, 'register');
    expect(find.byType(Dialog), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    expect(find.byType(Dialog), findsNothing);

    await press(tester, 'register');
    expect(find.byType(Dialog), findsOneWidget, reason: 'the form works again');

    await tester.tap(find.text('Back'));
    await settle(tester);
    expect(find.byType(Dialog), findsNothing);
  });

  testMurkio('widgets outside a form share the default one of the client', (
    tester,
  ) async {
    final api = canvasApi(
      routes: {'POST /v1/login': (_) => Answer.data(tokens())},
    );
    Murkio.reset();
    final murkio = await Murkio.initialize(
      publishableKey: 'pk_shared',
      apiUrl: 'https://api.example.com',
      storage: MurkioMemoryStorage(),
      httpClient: api.client,
      locale: 'en',
    );
    final logins = <MurkioSession>[];
    await pumpApp(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MurkioIdentityEmailInput(key: ValueKey('email')),
          const MurkioIdentityPasswordInput(key: ValueKey('password')),
          MurkioIdentityLoginButton(
            key: const ValueKey('login'),
            onLogin: logins.add,
            builder:
                (context, onPressed, busy) => GestureDetector(
                  onTap: onPressed,
                  child: Text(busy ? 'Wait' : 'Enter'),
                ),
          ),
          MurkioAuthBuilder(
            builder:
                (context, session) =>
                    Text(session == null ? 'signed out' : 'signed in'),
          ),
        ],
      ),
    );
    expect(find.text('signed out'), findsOneWidget);

    await fill(tester);
    await tester.tap(find.text('Enter'));
    await settle(tester);

    expect(logins, hasLength(1));
    expect(find.text('signed in'), findsOneWidget);
    expect(identical(Murkio.instance, murkio), isTrue);

    await murkio.signOut();
    await settle(tester);
    expect(find.text('signed out'), findsOneWidget);
  });

  testMurkio('the password field submits from the keyboard', (tester) async {
    final api = canvasApi(
      routes: {'POST /v1/login': (_) => Answer.data(tokens())},
    );
    final murkio = await startMurkio(api);
    await pumpApp(tester, form(murkio));

    await fill(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(murkio.isSignedIn, isTrue);
  });
}
