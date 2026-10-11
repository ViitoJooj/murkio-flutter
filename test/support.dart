import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:murkio_identity/murkio_identity.dart';

/// libs/spec, shared with the service and the other SDKs. Tests run from the
/// package directory.
final Directory specDir = Directory('../../spec');

Object? readSpec(String path) =>
    jsonDecode(File('${specDir.path}/$path').readAsStringSync());

/// A raw document from a vector reference (`file.json` or `file.json#field`).
Object? rawDocumentAt(String ref) {
  final parts = ref.split('#');
  final value = readSpec(parts[0]);
  return parts.length > 1 ? (value as Map)[parts[1]] : value;
}

/// The same document after the SDK's own validation.
CanvasDocument documentAt(String ref) {
  final result = sanitizeDocument(rawDocumentAt(ref));
  expect(result.problems, isEmpty, reason: ref);
  return result.document!;
}

final Map<String, dynamic> vectors =
    readSpec('client/vectors.json') as Map<String, dynamic>;

PublicConfig? configFrom(Object? json) =>
    json == null ? null : PublicConfig.fromJson(json);

/// One request the fake API received.
class Call {
  Call(this.method, this.path, this.body, this.headers);

  final String method;
  final String path;
  final Object? body;
  final Map<String, String> headers;
}

typedef Handler = FutureOr<Answer> Function(Call call);

/// What the fake API answers.
class Answer {
  const Answer(this.status, [this.body, this.headers = const {}]);

  /// An API error with one detail.
  Answer.error(this.status, String code)
    : body = {
        'details': [
          {'code': code, 'message': code},
        ],
      },
      headers = const {};

  /// A `{"data": ...}` answer.
  Answer.data(Object? data, {this.status = 200, this.headers = const {}})
    : body = {'data': data};

  final int status;
  final Object? body;
  final Map<String, String> headers;
}

/// An HTTP client that answers from a table of "METHOD /path" handlers and
/// records the calls. A handler may throw to simulate a network failure.
class FakeApi {
  FakeApi([Map<String, Handler>? routes]) : routes = routes ?? {};

  final Map<String, Handler> routes;
  final List<Call> calls = [];

  List<Call> to(String path) => calls.where((c) => c.path == path).toList();

  late final http.Client client = MockClient((request) async {
    final call = Call(
      request.method,
      request.url.path,
      request.body.isEmpty ? null : jsonDecode(request.body),
      request.headers,
    );
    calls.add(call);
    final handler = routes['${call.method} ${call.path}'];
    if (handler == null) {
      return http.Response(
        jsonEncode({
          'details': [
            {'code': 'test-404', 'message': call.path},
          ],
        }),
        404,
      );
    }
    final answer = await handler(call);
    final empty = answer.status == 204 || answer.status == 304;
    return http.Response.bytes(
      empty || answer.body == null
          ? const []
          : utf8.encode(jsonEncode(answer.body)),
      answer.status,
      headers: {'content-type': 'application/json', ...answer.headers},
    );
  });
}

String jwt(Map<String, Object?> claims) {
  String encode(Object? value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'EdDSA', 'typ': 'JWT'})}.${encode(claims)}.signature';
}

int _counter = 0;

/// A fresh token pair as the API returns it.
Map<String, Object?> tokens({
  int expiresIn = 900,
  String sessionId = 'session-1',
  DateTime? now,
}) {
  _counter++;
  final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  return {
    'access_token': jwt({
      'iss': 'enterprise-auth',
      'sub': 'user-1',
      'aud': 'app-1',
      'sid': sessionId,
      'roles': ['user'],
      'iat': seconds,
      'exp': seconds + expiresIn,
      'jti': 'j$_counter',
    }),
    'token_type': 'Bearer',
    'expires_in': expiresIn,
    'refresh_token': 'rt_$_counter',
    'session_id': sessionId,
  };
}

Map<String, Object?> bootstrapJson({
  Object? document,
  bool password = true,
  List<String> providers = const [],
  int version = 3,
}) {
  return {
    'application_id': 'app-1',
    'issuer': 'enterprise-auth',
    'jwks_url': '/v1/applications/app-1/jwks.json',
    'config': {
      'methods': {'password': password},
      'mfa': {'mode': 'optional'},
      'oauth_providers': providers,
      'signup': {'login_on_verify': true},
    },
    'canvas': {
      'version': version,
      'document': document ?? readSpec('canvas/default.json'),
    },
  };
}

/// A client that talks to [api], keeps the session in memory and does not
/// watch the app lifecycle. It is disposed with the test.
Future<Murkio> startMurkio(
  FakeApi api, {
  String? locale = 'en',
  MurkioStorage? storage,
  String? oauthRedirectUrl,
  MurkioUrlOpener? openUrl,
  DateTime Function()? now,
  String key = 'pk_test',
}) async {
  final murkio = Murkio(
    publishableKey: key,
    apiUrl: 'https://api.example.com',
    locale: locale,
    storage: storage ?? MurkioMemoryStorage(),
    httpClient: api.client,
    oauthRedirectUrl: oauthRedirectUrl,
    openUrl: openUrl,
    now: now,
    observeLifecycle: false,
  );
  liveClients.add(murkio);
  addTearDown(murkio.dispose);
  await murkio.start();
  return murkio;
}

/// Every client the running test created (widget tests dispose them before
/// the test body ends).
final List<Murkio> liveClients = [];
