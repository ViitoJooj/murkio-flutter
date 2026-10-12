import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:murkio_identity/murkio_identity.dart';

import 'support.dart';
import 'widget_support.dart';

void main() {
  group('the canvas is drawn where the web draws it', () {
    final layouts = (vectors['layout'] as List).cast<Map<String, dynamic>>();
    for (var index = 0; index < layouts.length; index++) {
      final entry = layouts[index];
      final expected = entry['expect'] as Map<String, dynamic>;
      final width = (entry['width'] as num).toDouble();

      testMurkio(
        'layout #$index: ${(entry['document'] as String).split('/').last} '
        'at $width is ${expected['layout']}',
        (tester) async {
          final raw = rawDocumentAt(entry['document'] as String);
          final screen = entry['screen'] == 'sign_up'
              ? MurkioScreen.signUp
              : MurkioScreen.signIn;

          if (entry['config'] == null) {
            await pumpApp(
              tester,
              MurkioIdentityCanvas(preview: raw, screen: screen, locale: 'en'),
              width: width,
            );
          } else {
            final config = entry['config'] as Map<String, dynamic>;
            final api = FakeApi({
              'GET /v1/client': (_) => Answer.data({
                ...bootstrapJson(document: raw),
                'config': config,
              }),
            });
            final murkio = await startMurkio(
              api,
              oauthRedirectUrl: entry['oauth'] == true
                  ? 'https://app.example.com/callback'
                  : null,
            );
            await pumpApp(
              tester,
              MurkioIdentityCanvas(murkio: murkio, screen: screen),
              width: width,
            );
          }

          final frame = find.byKey(const ValueKey('murkio-frame'));
          final origin = tester.getTopLeft(frame);
          final want = expected['frame'] as Map<String, dynamic>;
          expect(
            tester.getSize(frame).width,
            closeTo(want['width'] as num, 0.01),
          );
          expect(
            tester.getSize(frame).height,
            closeTo(want['height'] as num, 0.01),
          );
          expect(
            origin.dx,
            closeTo((width - (want['width'] as num)) / 2, 0.01),
            reason: 'the frame is centered in its container',
          );

          expect(
            elementIds(tester),
            expected['paint'],
            reason: 'children of the stack, bottom to top',
          );
          (expected['items'] as Map<String, dynamic>).forEach((id, value) {
            final rect = tester
                .getRect(find.byKey(ValueKey('murkio-el-$id')))
                .shift(-origin);
            final item = value as Map<String, dynamic>;
            expect(rect.left, closeTo(item['x'] as num, 0.01), reason: '$id.x');
            expect(rect.top, closeTo(item['y'] as num, 0.01), reason: '$id.y');
            expect(
              rect.width,
              closeTo(item['w'] as num, 0.01),
              reason: '$id.w',
            );
            expect(
              rect.height,
              closeTo(item['h'] as num, 0.01),
              reason: '$id.h',
            );
          });
        },
      );
    }
  });

  group('sign-in on the canvas', () {
    testMurkio('signs in with the typed email and password', (tester) async {
      final api = canvasApi(
        routes: {'POST /v1/login': (_) => Answer.data(tokens())},
      );
      final murkio = await startMurkio(api);
      final logins = <MurkioSession>[];
      await pumpApp(
        tester,
        MurkioIdentityCanvas(murkio: murkio, onLogin: logins.add),
      );

      await tester.enterText(fieldOf('email'), '  Ana@Example.com ');
      await tester.enterText(fieldOf('password'), 'S3nha!forte');
      await tapElement(tester, 'login');

      expect(api.to('/v1/login').single.body, {
        'email': 'ana@example.com',
        'password': 'S3nha!forte',
      });
      expect(logins.single.sessionId, 'session-1');
      expect(murkio.isSignedIn, isTrue);
      expect(
        murkio.currentSession!.ephemeral,
        isTrue,
        reason: 'the default canvas has the box unchecked',
      );
      expect(
        tester.widget<TextField>(fieldOf('password')).controller!.text,
        isEmpty,
        reason: 'the password is dropped once it was used',
      );
    });

    testMurkio('the keyboard action of the password field submits', (
      tester,
    ) async {
      final api = canvasApi(
        routes: {'POST /v1/login': (_) => Answer.data(tokens())},
      );
      final murkio = await startMurkio(api);
      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));

      await tester.enterText(fieldOf('email'), 'ana@example.com');
      await tester.enterText(fieldOf('password'), 'S3nha!forte');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);

      expect(api.to('/v1/login'), hasLength(1));
      expect(murkio.isSignedIn, isTrue);
    });

    testMurkio('"keep me signed in" checked keeps the session', (tester) async {
      final api = canvasApi(
        routes: {'POST /v1/login': (_) => Answer.data(tokens())},
      );
      final murkio = await startMurkio(api);
      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));

      expect(find.bySemanticsLabel('Keep me signed in'), findsOneWidget);
      await tapElement(tester, 'keep_logged');
      await tester.enterText(fieldOf('email'), 'ana@example.com');
      await tester.enterText(fieldOf('password'), 'S3nha!forte');
      await tapElement(tester, 'login');

      expect(murkio.currentSession!.ephemeral, isFalse);
    });

    testMurkio('a canvas without the checkbox keeps the session', (
      tester,
    ) async {
      final document = cloneDefault();
      removeElement(document, 'keep_logged');
      final api = canvasApi(
        routes: {'POST /v1/login': (_) => Answer.data(tokens())},
        document: document,
      );
      final murkio = await startMurkio(api);
      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));

      await tester.enterText(fieldOf('email'), 'ana@example.com');
      await tester.enterText(fieldOf('password'), 'S3nha!forte');
      await tapElement(tester, 'login');

      expect(murkio.currentSession!.ephemeral, isFalse);
    });

    testMurkio('shows the translated error and reports it', (tester) async {
      final api = canvasApi(
        routes: {'POST /v1/login': (_) => Answer.error(401, 'rsb-00')},
      );
      final murkio = await startMurkio(api, locale: 'pt-BR');
      final errors = <MurkioException>[];
      await pumpApp(
        tester,
        MurkioIdentityCanvas(murkio: murkio, onError: errors.add),
      );

      expect(find.text('Entrar'), findsNWidgets(2), reason: 'title and button');
      await tester.enterText(fieldOf('email'), 'ana@example.com');
      await tester.enterText(fieldOf('password'), 'errada');
      await tapElement(tester, 'login');

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('murkio-el-error')),
          matching: find.text(translateError('rsb-00', 'pt-BR')),
        ),
        findsOneWidget,
      );
      expect(errors.single.code, 'rsb-00');
      expect(murkio.isSignedIn, isFalse);
    });

    testMurkio('buttons do nothing while a request runs', (tester) async {
      final gate = Completer<void>();
      final api = canvasApi(
        routes: {
          'POST /v1/login': (_) async {
            await gate.future;
            return Answer.data(tokens());
          },
        },
      );
      final murkio = await startMurkio(api);
      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));

      await tester.enterText(fieldOf('email'), 'ana@example.com');
      await tester.enterText(fieldOf('password'), 'S3nha!forte');
      await tapElement(tester, 'login');
      await tapElement(tester, 'login');
      await tapElement(tester, 'register');
      expect(api.calls.where((c) => c.path != '/v1/client'), hasLength(1));

      gate.complete();
      await settle(tester);
      expect(murkio.isSignedIn, isTrue);
    });

    testMurkio('the eye shows and hides the password', (tester) async {
      final murkio = await startMurkio(canvasApi());
      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));

      expect(tester.widget<TextField>(fieldOf('password')).obscureText, isTrue);
      await tester.tap(find.byKey(const ValueKey('murkio-password-toggle')));
      await tester.pump();
      expect(
        tester.widget<TextField>(fieldOf('password')).obscureText,
        isFalse,
      );
    });

    testMurkio(
      'fields tell the keyboard and the password manager what they are',
      (tester) async {
        final murkio = await startMurkio(canvasApi());
        await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));

        final email = tester.widget<TextField>(fieldOf('email'));
        expect(email.keyboardType, TextInputType.emailAddress);
        expect(email.autocorrect, isFalse);
        expect(email.autofillHints, contains(AutofillHints.username));
        expect(tester.widget<TextField>(fieldOf('password')).autofillHints, [
          AutofillHints.password,
        ]);
        expect(find.bySemanticsLabel(RegExp('Email')), findsWidgets);
      },
    );
  });

  group('built-in screens', () {
    testMurkio('signup asks for the email code and signs in', (tester) async {
      final api = canvasApi(
        routes: {
          'POST /v1/signup': (_) => const Answer(204),
          'POST /v1/email/verification': (_) => const Answer(204),
          'POST /v1/email/verification/confirm': (_) => Answer.data(tokens()),
        },
      );
      final murkio = await startMurkio(api);
      final steps = <String>[];
      final logins = <MurkioSession>[];
      await pumpApp(
        tester,
        MurkioIdentityCanvas(
          murkio: murkio,
          onStep: steps.add,
          onLogin: logins.add,
        ),
      );

      await tester.enterText(fieldOf('email'), 'ana@example.com');
      await tester.enterText(fieldOf('password'), 'S3nha!forte');
      await tapElement(tester, 'register');

      expect(api.to('/v1/signup').single.body, {
        'email': 'ana@example.com',
        'password': 'S3nha!forte',
        'locale': 'en',
      });
      expect(steps, ['verify_email']);
      expect(find.byKey(const ValueKey('murkio-frame')), findsNothing);
      expect(find.text('Confirm your email'), findsOneWidget);
      expect(
        find.text('We sent a 6-digit code to ana@example.com.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Send a new code'));
      await settle(tester);
      expect(api.to('/v1/email/verification'), hasLength(1));
      expect(find.byKey(const ValueKey('murkio-step-message')), findsOneWidget);

      await tester.enterText(find.byType(TextField), ' 123456 ');
      await tester.tap(find.text('Confirm'));
      await settle(tester);

      expect(api.to('/v1/email/verification/confirm').single.body, {
        'email': 'ana@example.com',
        'code': '123456',
        'password': 'S3nha!forte',
      });
      expect(logins, hasLength(1));
      expect(find.byKey(const ValueKey('murkio-frame')), findsOneWidget);
    });

    testMurkio('two-step verification, with a wrong code first', (
      tester,
    ) async {
      var attempts = 0;
      final api = canvasApi(
        routes: {
          'POST /v1/login': (_) => Answer.data({
            'mfa': {'token': 'mfa_1', 'enrollment_required': false},
          }),
          'POST /v1/mfa/challenge/verify': (_) => ++attempts == 1
              ? Answer.error(400, 'rsb-09')
              : Answer.data(tokens()),
        },
      );
      final murkio = await startMurkio(api);
      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));

      await tester.enterText(fieldOf('email'), 'ana@example.com');
      await tester.enterText(fieldOf('password'), 'S3nha!forte');
      await tapElement(tester, 'login');
      expect(find.text('Two-step verification'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '111111');
      await tester.tap(find.text('Verify'));
      await settle(tester);
      expect(find.text(translateError('rsb-09')), findsOneWidget);

      await tester.enterText(find.byType(TextField), '654321');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(murkio.isSignedIn, isTrue);
    });

    testMurkio('forced enrollment shows the key and the recovery codes', (
      tester,
    ) async {
      final api = canvasApi(
        routes: {
          'POST /v1/login': (_) => Answer.data({
            'mfa': {'token': 'mfa_2', 'enrollment_required': true},
          }),
          'POST /v1/mfa/challenge/enroll': (_) => Answer.data({
            'secret': 'JBSWY3DPEHPK3PXP',
            'otpauth_uri': 'otpauth://totp/App:ana?secret=JBSWY3DPEHPK3PXP',
          }),
          'POST /v1/mfa/challenge/enroll/confirm': (_) => Answer.data({
            'recovery_codes': ['aaaa-bbbb', 'cccc-dddd'],
            'session': tokens(),
          }),
        },
      );
      final opened = <Uri>[];
      final murkio = await startMurkio(
        api,
        openUrl: (url) async {
          opened.add(url);
          return true;
        },
      );
      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));

      await tester.enterText(fieldOf('email'), 'ana@example.com');
      await tester.enterText(fieldOf('password'), 'S3nha!forte');
      await tapElement(tester, 'login');
      expect(
        find.textContaining('JBSWY3DPEHPK3PXP', findRichText: true),
        findsOneWidget,
      );

      await tester.tap(find.text('Open in authenticator app'));
      await settle(tester);
      expect(opened.single.scheme, 'otpauth');

      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text('Activate'));
      await settle(tester);
      expect(find.textContaining('aaaa-bbbb'), findsOneWidget);
      expect(find.text('Back'), findsNothing);
      expect(
        murkio.isSignedIn,
        isFalse,
        reason: 'not before the codes are saved',
      );

      await tester.tap(find.text('I saved them'));
      await settle(tester);
      expect(murkio.isSignedIn, isTrue);
    });

    testMurkio('password reset returns to the canvas with a notice', (
      tester,
    ) async {
      final api = canvasApi(
        routes: {
          'POST /v1/password/reset': (_) => const Answer(204),
          'POST /v1/password/reset/confirm': (_) => const Answer(204),
        },
      );
      final murkio = await startMurkio(api);
      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));

      await tester.enterText(fieldOf('email'), 'Ana@Example.com');
      await tapElement(tester, 'forgot');
      expect(find.text('Reset your password'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'ana@example.com',
      );

      await tester.tap(find.text('Send code'));
      await settle(tester);
      expect(api.to('/v1/password/reset').single.body, {
        'email': 'ana@example.com',
        'locale': 'en',
      });

      await tester.enterText(find.byType(TextField).at(0), '987654');
      await tester.enterText(find.byType(TextField).at(1), 'N0va!Senha#Forte');
      await tester.tap(find.text('Save password'));
      await settle(tester);

      expect(api.to('/v1/password/reset/confirm').single.body, {
        'email': 'ana@example.com',
        'code': '987654',
        'password': 'N0va!Senha#Forte',
      });
      expect(find.byKey(const ValueKey('murkio-frame')), findsOneWidget);
      expect(
        find.text('Password changed. Sign in with the new one.'),
        findsOneWidget,
      );
    });

    testMurkio('back returns to the canvas', (tester) async {
      final murkio = await startMurkio(canvasApi());
      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));

      await tapElement(tester, 'forgot');
      expect(find.byKey(const ValueKey('murkio-step-forgot')), findsOneWidget);
      await tester.tap(find.text('Back'));
      await settle(tester);
      expect(find.byKey(const ValueKey('murkio-frame')), findsOneWidget);
    });
  });

  group('what the application turned on', () {
    testMurkio('social buttons need a provider turned on and a return link', (
      tester,
    ) async {
      final document = rawDocumentAt(
        'canvas/fixtures/unpublishable/oauth-provider-disabled.json#document',
      );
      FakeApi api() => canvasApi(
        routes: {
          'POST /v1/oauth/google/authorize': (_) => Answer.data({
            'authorization_url': 'https://accounts.example.com/auth',
          }),
        },
        document: document,
        providers: ['google'],
      );

      final without = await startMurkio(api());
      await pumpApp(tester, MurkioIdentityCanvas(murkio: without));
      expect(find.byKey(const ValueKey('murkio-el-google')), findsNothing);

      final opened = <Uri>[];
      final withLink = await startMurkio(
        api(),
        oauthRedirectUrl: 'https://app.example.com/callback',
        openUrl: (url) async {
          opened.add(url);
          return true;
        },
      );
      await pumpApp(tester, MurkioIdentityCanvas(murkio: withLink));
      expect(find.text('Continue with Google'), findsOneWidget);

      await tapElement(tester, 'google');
      expect(opened.single.host, 'accounts.example.com');
    });

    testMurkio('without the password method its elements are gone', (
      tester,
    ) async {
      final document = rawDocumentAt(
        'canvas/fixtures/unpublishable/oauth-provider-disabled.json#document',
      );
      final api = canvasApi(
        document: document,
        password: false,
        providers: ['google'],
      );
      final murkio = await startMurkio(
        api,
        oauthRedirectUrl: 'https://app.example.com/callback',
      );
      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));

      expect(elementIds(tester).toSet(), {
        'title',
        'error',
        'divider',
        'google',
      });
      expect(find.byType(TextField), findsNothing);
    });

    testMurkio(
      'a published canvas that cannot sign in gives way to the default',
      (tester) async {
        final document = rawDocumentAt(
          'canvas/fixtures/unpublishable/missing-password-input.json#document',
        );
        final murkio = await startMurkio(canvasApi(document: document));
        await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));
        expect(
          find.byKey(const ValueKey('murkio-el-password')),
          findsOneWidget,
        );
      },
    );

    testMurkio('without the API the default canvas shows with an error', (
      tester,
    ) async {
      final api = FakeApi({
        'GET /v1/client': (_) => throw Exception('offline'),
      });
      final murkio = await startMurkio(api);
      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));

      expect(find.byKey(const ValueKey('murkio-el-email')), findsOneWidget);
      expect(find.text(translateError('unknown')), findsOneWidget);
    });

    testMurkio('the sign-up screen registers with a new password', (
      tester,
    ) async {
      final document = rawDocumentAt(
        'canvas/fixtures/valid/sign-up-screen.json#document',
      );
      final api = canvasApi(
        routes: {'POST /v1/signup': (_) => const Answer(204)},
        document: document,
      );
      final murkio = await startMurkio(api);
      await pumpApp(
        tester,
        MurkioIdentityCanvas(murkio: murkio, screen: MurkioScreen.signUp),
      );

      expect(find.byKey(const ValueKey('murkio-el-login')), findsNothing);
      expect(tester.widget<TextField>(fieldOf('password')).autofillHints, [
        AutofillHints.newPassword,
      ]);
      await tester.enterText(fieldOf('email'), 'ana@example.com');
      await tester.enterText(fieldOf('password'), 'S3nha!forte');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(api.to('/v1/signup'), hasLength(1));
    });
  });

  group('preview, links and hosts', () {
    testMurkio('preview draws a document without calling anything', (
      tester,
    ) async {
      Murkio.reset();
      await pumpApp(
        tester,
        MurkioIdentityCanvas(
          preview: readSpec('canvas/default.json'),
          locale: 'pt-BR',
        ),
      );

      expect(find.text('Criar conta'), findsOneWidget);
      await tester.enterText(fieldOf('email'), 'ana@example.com');
      await tapElement(tester, 'login');
      await tapElement(tester, 'forgot');
      expect(find.byKey(const ValueKey('murkio-frame')), findsOneWidget);
    });

    testMurkio('without Murkio.initialize the canvas says what is missing', (
      tester,
    ) async {
      Murkio.reset();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MurkioIdentityCanvas())),
      );
      final error = tester.takeException();
      expect(error, isA<StateError>());
      expect((error as StateError).message, contains('Murkio.initialize'));
    });

    testMurkio('a nonsense preview falls back to the default canvas', (
      tester,
    ) async {
      await pumpApp(
        tester,
        const MurkioIdentityCanvas(preview: {'schema': 99}, locale: 'en'),
      );
      expect(find.text('Create account'), findsOneWidget);
    });

    testMurkio('links go to the app when it asks, else https opens outside', (
      tester,
    ) async {
      final document = cloneDefault();
      addElement(
        document,
        {
          'id': 'terms',
          'type': 'link',
          'props': {
            'text': {'default': 'Terms'},
            'href': '/terms',
          },
          'style': <String, Object?>{},
        },
        {'x': 32, 'y': 456, 'w': 160, 'h': 40, 'z': 1},
      );
      addElement(
        document,
        {
          'id': 'site',
          'type': 'link',
          'props': {
            'text': {'default': 'Site'},
            'href': 'https://example.com/about',
          },
          'style': <String, Object?>{},
        },
        {'x': 200, 'y': 456, 'w': 160, 'h': 40, 'z': 1},
      );

      final opened = <Uri>[];
      final murkio = await startMurkio(
        canvasApi(document: document),
        openUrl: (url) async {
          opened.add(url);
          return true;
        },
      );
      final tapped = <String>[];
      await pumpApp(
        tester,
        MurkioIdentityCanvas(murkio: murkio, onLink: tapped.add),
      );
      await tapElement(tester, 'terms');
      await tapElement(tester, 'site');
      expect(tapped, ['/terms', 'https://example.com/about']);
      expect(opened, isEmpty);

      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio));
      await tapElement(tester, 'terms');
      await tapElement(tester, 'site');
      expect(opened.single.toString(), 'https://example.com/about');
    });

    for (final host in ['cupertino', 'widgets']) {
      testMurkio('works in an app without Material ($host)', (tester) async {
        final api = canvasApi(
          routes: {'POST /v1/login': (_) => Answer.data(tokens())},
        );
        final murkio = await startMurkio(api);
        await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio), host: host);

        await tester.enterText(fieldOf('email'), 'ana@example.com');
        await tester.enterText(fieldOf('password'), 'S3nha!forte');
        await tapElement(tester, 'login');
        expect(murkio.isSignedIn, isTrue);
        expect(tester.takeException(), isNull);
      });
    }

    testMurkio('the locale follows the app when nothing else is said', (
      tester,
    ) async {
      final murkio = await startMurkio(canvasApi(), locale: null);
      await pumpApp(
        tester,
        MurkioIdentityCanvas(murkio: murkio),
        appLocale: const Locale('pt', 'BR'),
      );
      expect(find.text('Criar conta'), findsOneWidget);

      await pumpApp(
        tester,
        MurkioIdentityCanvas(murkio: murkio, locale: 'en'),
        appLocale: const Locale('pt', 'BR'),
      );
      expect(find.text('Create account'), findsOneWidget);
    });

    testMurkio('a huge system font is held back inside the frame', (
      tester,
    ) async {
      final murkio = await startMurkio(canvasApi());
      await pumpApp(tester, MurkioIdentityCanvas(murkio: murkio), textScale: 3);

      final title = tester.element(
        find.descendant(
          of: find.byKey(const ValueKey('murkio-el-title')),
          matching: find.byType(Text),
        ),
      );
      expect(MediaQuery.textScalerOf(title).scale(10), closeTo(13, 0.001));
    });
  });
}
