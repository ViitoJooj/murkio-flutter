import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:murkio_identity/murkio_identity.dart';
import 'package:murkio_identity/src/canvas/layout.dart';
import 'package:murkio_identity/src/canvas/validate.dart';
import 'package:murkio_identity/src/crypto.dart';
import 'package:murkio_identity/src/models.dart' show decodeClaims;

import 'support.dart';

// libs/spec/client/vectors.json is run by every client SDK. The @murkio/html
// tests run it against the browser code, so passing here means this SDK
// answers like the web does.
void main() {
  group('client vectors: small helpers', () {
    test('hashes the publishable key', () {
      (vectors['key_hash'] as Map<String, dynamic>).forEach((value, hash) {
        expect(fnv1a32(value), hash, reason: value);
      });
    });

    test('derives the PKCE challenge', () {
      for (final entry
          in (vectors['pkce'] as List).cast<Map<String, dynamic>>()) {
        expect(codeChallenge(entry['verifier'] as String), entry['challenge']);
      }
    });

    test('reads the claims of an access token', () {
      final entry = vectors['claims'] as Map<String, dynamic>;
      final expected = entry['expect'] as Map<String, dynamic>;
      final claims = decodeClaims(entry['token'] as String)!;
      expect(claims.subject, expected['sub']);
      expect(claims.sessionId, expected['sid']);
      expect(claims.expiresAt.millisecondsSinceEpoch ~/ 1000, expected['exp']);
      expect(claims.roles, expected['roles']);
    });

    test('parses every color form', () {
      for (final entry
          in (vectors['colors'] as List).cast<Map<String, dynamic>>()) {
        final rgba = (entry['rgba'] as List).cast<int>();
        final argb = parseColor(entry['color'])!;
        expect(
          [
            (argb >> 16) & 0xff,
            (argb >> 8) & 0xff,
            argb & 0xff,
            (argb >> 24) & 0xff,
          ],
          rgba,
          reason: entry['color'] as String,
        );
      }
      expect(parseColor('#12'), isNull);
      expect(parseColor('red'), isNull);
      expect(parseColor('#gggggg'), isNull);
    });

    test('picks the text of a locale', () {
      for (final entry
          in (vectors['text'] as List).cast<Map<String, dynamic>>()) {
        final raw = entry['text'] as Map<String, dynamic>;
        final text = LocalizedText(
          raw['default'] as String,
          (raw['i18n'] as Map<String, dynamic>).cast<String, String>(),
        );
        expect(
          text.pick(entry['locale'] as String),
          entry['expect'],
          reason: entry['locale'] as String,
        );
      }
      expect(const LocalizedText('x', {'pt-BR': 'y'}).pick('pt_BR'), 'y');
    });

    test('speaks the same built-in strings', () {
      for (final entry
          in (vectors['strings'] as List).cast<Map<String, dynamic>>()) {
        expect(
          murkioString(entry['locale'] as String, entry['key'] as String),
          entry['expect'],
        );
      }
      for (final locale in ['en', 'pt-BR']) {
        final table =
            readSpec('client/strings/$locale.json') as Map<String, dynamic>;
        const params = {'email': '{email}', 'provider': '{provider}'};
        table.forEach((key, text) {
          expect(murkioString(locale, key, params), text, reason: key);
        });
      }
    });

    test('translates the error codes', () {
      for (final entry
          in (vectors['errors'] as List).cast<Map<String, dynamic>>()) {
        expect(
          translateError(entry['code'] as String, entry['locale'] as String),
          entry['expect'],
          reason: '${entry['locale']} ${entry['code']}',
        );
      }
    });
  });

  group('client vectors: canvas', () {
    final layouts = (vectors['layout'] as List).cast<Map<String, dynamic>>();
    for (var index = 0; index < layouts.length; index++) {
      final entry = layouts[index];
      final expected = entry['expect'] as Map<String, dynamic>;
      test('layout #$index: ${(entry['document'] as String).split('/').last} '
          'at ${entry['width']} is ${expected['layout']}', () {
        final document = documentAt(entry['document'] as String);
        final screen =
            entry['screen'] == 'sign_up' ? document.signUp! : document.signIn;
        final placement = place(
          screen,
          (entry['width'] as num).toDouble(),
          config: configFrom(entry['config']),
          oauth: entry['oauth'] as bool,
        );

        expect(placement.layout.name, expected['layout']);
        final frame = expected['frame'] as Map<String, dynamic>;
        expect(placement.frameWidth, closeTo(frame['width'] as num, 0.01));
        expect(placement.frameHeight, closeTo(frame['height'] as num, 0.01));
        expect([for (final e in placement.order) e.id], expected['order']);
        expect([for (final e in placement.paint) e.id], expected['paint']);

        final items = expected['items'] as Map<String, dynamic>;
        expect(placement.rects.keys.toSet(), items.keys.toSet());
        items.forEach((id, value) {
          final rect = placement.rects[id]!;
          final want = value as Map<String, dynamic>;
          expect(rect.x, closeTo(want['x'] as num, 0.01), reason: '$id.x');
          expect(rect.y, closeTo(want['y'] as num, 0.01), reason: '$id.y');
          expect(rect.w, closeTo(want['w'] as num, 0.01), reason: '$id.w');
          expect(rect.h, closeTo(want['h'] as num, 0.01), reason: '$id.h');
        });
      });
    }

    test('shows what the application turned on', () {
      for (final entry
          in (vectors['visibility'] as List).cast<Map<String, dynamic>>()) {
        final document = documentAt(entry['document'] as String);
        final signUp = entry['screen'] == 'sign_up';
        final screen = signUp ? document.signUp! : document.signIn;
        final config = configFrom(entry['config']);
        final oauth = entry['oauth'] as bool;
        final expected = entry['expect'] as Map<String, dynamic>;
        final reason = '${entry['document']} ${entry['screen']} oauth=$oauth';
        expect(
          [
            for (final element in readingOrder(screen))
              if (isVisible(element, config, oauth: oauth)) element.id,
          ],
          expected['visible'],
          reason: reason,
        );
        expect(
          submitAction(screen, signUp: signUp, config: config, oauth: oauth),
          expected['submit'],
          reason: reason,
        );
      }
    });

    test(
      'falls back to the default canvas when the published one cannot sign in',
      () {
        for (final entry
            in (vectors['pick_canvas'] as List).cast<Map<String, dynamic>>()) {
          final raw = rawDocumentAt(entry['document'] as String);
          final config = configFrom(entry['config']);
          final own = sanitizeDocument(raw).document!;
          expect(
            isUsable(own.signIn, config) ? 'document' : 'default',
            entry['expect'],
            reason: '${entry['document']} ${jsonEncode(entry['config'])}',
          );
          final picked = pickCanvas(raw, config);
          expect(
            identical(picked, defaultCanvas()),
            !isUsable(own.signIn, config),
          );
        }
        expect(identical(pickCanvas(null, null), defaultCanvas()), isTrue);
        expect(
          identical(pickCanvas('nonsense', null), defaultCanvas()),
          isTrue,
        );
      },
    );
  });

  group('client vectors: flows', () {
    final flows = vectors['flows'] as Map<String, dynamic>;
    final locale = flows['locale'] as String;
    final refreshToken = (flows['tokens'] as Map)['refresh_token'];

    for (final scenario
        in (flows['cases'] as List).cast<Map<String, dynamic>>()) {
      test(scenario['name'] as String, () async {
        final queue = <Map<String, dynamic>>[];
        final client = MockClient((request) async {
          expect(
            queue,
            isNotEmpty,
            reason: 'unexpected ${request.method} ${request.url.path}',
          );
          final step = queue.removeAt(0);
          expect(
            '${request.method} ${request.url.path}',
            '${step['method']} ${step['path']}',
          );
          expect(
            request.body.isEmpty ? null : jsonDecode(request.body),
            step['body'],
          );
          expect(request.headers['Authorization'], 'Bearer pk_vectors');
          final status = step['status'] as int;
          if (status == 0) throw http.ClientException('network down');
          return http.Response.bytes(
            status == 204 || step['response'] == null
                ? const []
                : utf8.encode(jsonEncode(step['response'])),
            status,
          );
        });
        final murkio = Murkio(
          publishableKey: 'pk_vectors',
          apiUrl: 'https://api.example.com',
          locale: locale,
          storage: MurkioMemoryStorage(),
          httpClient: client,
          observeLifecycle: false,
        );
        addTearDown(murkio.dispose);
        await murkio.start();
        final flow = FlowController(murkio);
        addTearDown(flow.dispose);

        for (final step
            in (scenario['steps'] as List).cast<Map<String, dynamic>>()) {
          queue.addAll((step['http'] as List).cast<Map<String, dynamic>>());
          final args = step['args'] as Map<String, dynamic>;
          final credentials = MurkioCredentials(
            email: args['email'] as String? ?? '',
            password: args['password'] as String? ?? '',
            keepLogged: args['keep_logged'] == true,
          );
          final call = step['call'] as String;
          switch (call) {
            case 'login':
              await flow.login(credentials);
            case 'register':
              await flow.register(credentials);
            case 'confirm_email':
              await flow.confirmEmail(
                args['code'] as String,
                args['password'] as String?,
              );
            case 'resend_email':
              await flow.resendEmail();
            case 'verify_mfa':
              await flow.verifyMfa(args['code'] as String);
            case 'confirm_enrollment':
              await flow.confirmEnrollment(args['code'] as String);
            case 'finish_recovery':
              await flow.finishRecovery();
            case 'forgot':
              flow.forgot(args['email'] as String);
            case 'request_reset':
              await flow.requestReset(args['email'] as String);
            case 'reset_password':
              await flow.resetPassword(
                args['code'] as String,
                args['password'] as String,
              );
            case 'back':
              flow.back();
            default:
              fail('unknown call $call');
          }
          expect(queue, isEmpty, reason: '$call left requests unsent');

          final state = flow.state;
          final expected = step['expect'] as Map<String, dynamic>;
          expect(state.busy, isFalse);
          expect(state.step.name, expected['step'], reason: call);
          expect(state.error?.code, expected['error'], reason: call);
          expect(state.notice, expected['notice'], reason: call);
          expect(murkio.isSignedIn, expected['signed_in'], reason: call);
          if (expected['signed_in'] == true) {
            final session = murkio.currentSession!;
            expect(session.ephemeral, expected['ephemeral']);
            expect(session.sessionId, expected['session_id']);
            expect(session.refreshToken, refreshToken);
          }
          if (expected.containsKey('email')) {
            expect(flow.currentEmail, expected['email']);
          }
          final current = state.step;
          if (current is VerifyEmailStep) {
            expect(current.email, expected['email']);
            expect(current.needsPassword, expected['needs_password']);
          }
          if (current is ResetStep) expect(current.email, expected['email']);
          if (current is MfaEnrollStep) {
            expect(current.secret, expected['secret']);
            expect(current.otpauthUri, expected['otpauth_uri']);
          }
          if (current is RecoveryCodesStep) {
            expect(current.codes, expected['codes']);
          }
        }
      });
    }
  });
}
