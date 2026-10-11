import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'models.dart';

/// Where the identity API lives unless the app says otherwise.
const String defaultApiUrl = 'https://api.mukio.com';

/// An answer of the API: the status, the `data` field and the headers.
class ApiResponse {
  const ApiResponse(this.status, this.data, this.headers);

  final int status;
  final Object? data;
  final Map<String, String> headers;
}

/// The answer of the bootstrap route, which may be "nothing changed".
class BootstrapResponse {
  const BootstrapResponse({
    required this.notModified,
    required this.etag,
    required this.data,
  });

  final bool notModified;
  final String? etag;
  final ClientBootstrap? data;
}

/// The secret and the link of a 2FA enrollment.
class MfaEnrollment {
  const MfaEnrollment({required this.secret, required this.otpauthUri});

  final String secret;
  final String otpauthUri;
}

/// The recovery codes and the session of a confirmed 2FA enrollment.
class MfaEnrollmentResult {
  const MfaEnrollmentResult({
    required this.recoveryCodes,
    required this.session,
  });

  final List<String> recoveryCodes;
  final TokenPair session;
}

/// ApiClient talks to the identity API with the publishable key. Every method
/// maps one route; errors come back as [MurkioException] with the API code.
/// It holds no state: tokens live in the session manager.
class ApiClient {
  ApiClient({
    required String publishableKey,
    String? apiUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
  }) : _publishableKey = publishableKey,
       apiUrl = (apiUrl ?? defaultApiUrl).replaceAll(RegExp(r'/+$'), ''),
       _ownsHttp = httpClient == null,
       _http = httpClient ?? http.Client();

  final String apiUrl;
  final Duration timeout;
  final String _publishableKey;
  final http.Client _http;
  final bool _ownsHttp;

  Future<ApiResponse> request(
    String method,
    String path, {
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    final request = http.Request(method, Uri.parse(apiUrl + path));
    request.headers['Authorization'] = 'Bearer $_publishableKey';
    request.headers.addAll(headers);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(timeout),
      );
    } catch (error) {
      // No answer at all (offline, DNS, TLS, timeout): the one error the app
      // may want to retry.
      throw MurkioException('network', 0, message: error.toString());
    }

    Object? json;
    if (response.statusCode != 204 &&
        response.statusCode != 304 &&
        response.bodyBytes.isNotEmpty) {
      try {
        json = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        json = null;
      }
    }

    final ok = response.statusCode >= 200 && response.statusCode < 300;
    if (!ok && response.statusCode != 304) {
      throw MurkioException.fromResponse(response.statusCode, json);
    }
    return ApiResponse(
      response.statusCode,
      json is Map ? json['data'] : null,
      response.headers,
    );
  }

  Future<BootstrapResponse> bootstrap({String? etag}) async {
    final response = await request(
      'GET',
      '/v1/client',
      headers: etag == null ? const {} : {'If-None-Match': etag},
    );
    return BootstrapResponse(
      notModified: response.status == 304,
      etag: response.headers['etag'],
      data:
          response.data == null
              ? null
              : ClientBootstrap.fromJson(response.data),
    );
  }

  Future<void> signup({
    required String email,
    required String password,
    required String locale,
  }) async {
    await request(
      'POST',
      '/v1/signup',
      body: {'email': email, 'password': password, 'locale': locale},
    );
  }

  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    final response = await request(
      'POST',
      '/v1/login',
      body: {'email': email, 'password': password},
    );
    return LoginResult.fromJson(response.data);
  }

  Future<void> sendVerification({
    required String email,
    required String locale,
  }) async {
    await request(
      'POST',
      '/v1/email/verification',
      body: {'email': email, 'locale': locale},
    );
  }

  /// Confirms the email. Returns the session (or the 2FA challenge), or null
  /// when the application does not sign in on verify.
  Future<LoginResult?> confirmVerification({
    required String email,
    required String code,
    required String password,
  }) async {
    final response = await request(
      'POST',
      '/v1/email/verification/confirm',
      body: {'email': email, 'code': code, 'password': password},
    );
    if (response.status == 204 || response.data == null) return null;
    return LoginResult.fromJson(response.data);
  }

  Future<void> requestPasswordReset({
    required String email,
    required String locale,
  }) async {
    await request(
      'POST',
      '/v1/password/reset',
      body: {'email': email, 'locale': locale},
    );
  }

  Future<void> confirmPasswordReset({
    required String email,
    required String code,
    required String password,
  }) async {
    await request(
      'POST',
      '/v1/password/reset/confirm',
      body: {'email': email, 'code': code, 'password': password},
    );
  }

  Future<TokenPair> refresh(String refreshToken) async {
    final response = await request(
      'POST',
      '/v1/token/refresh',
      body: {'refresh_token': refreshToken},
    );
    return TokenPair.fromJson(response.data);
  }

  Future<void> logout(String refreshToken) async {
    await request('POST', '/v1/logout', body: {'refresh_token': refreshToken});
  }

  Future<MurkioUser> me(String accessToken) async {
    final response = await request(
      'POST',
      '/v1/me',
      body: {'access_token': accessToken},
    );
    return MurkioUser.fromJson(response.data);
  }

  Future<TokenPair> verifyMfa({
    required String mfaToken,
    required String code,
  }) async {
    final response = await request(
      'POST',
      '/v1/mfa/challenge/verify',
      body: {'mfa_token': mfaToken, 'code': code},
    );
    return TokenPair.fromJson(response.data);
  }

  Future<MfaEnrollment> startMfaEnrollment({required String mfaToken}) async {
    final response = await request(
      'POST',
      '/v1/mfa/challenge/enroll',
      body: {'mfa_token': mfaToken},
    );
    final data = response.data;
    if (data is Map &&
        data['secret'] is String &&
        data['otpauth_uri'] is String) {
      return MfaEnrollment(
        secret: data['secret'] as String,
        otpauthUri: data['otpauth_uri'] as String,
      );
    }
    throw MurkioException('unknown', 0, message: 'unexpected enrollment');
  }

  Future<MfaEnrollmentResult> confirmMfaEnrollment({
    required String mfaToken,
    required String code,
  }) async {
    final response = await request(
      'POST',
      '/v1/mfa/challenge/enroll/confirm',
      body: {'mfa_token': mfaToken, 'code': code},
    );
    final data = response.data;
    if (data is Map && data['recovery_codes'] is List) {
      return MfaEnrollmentResult(
        recoveryCodes: List.unmodifiable(
          (data['recovery_codes'] as List).whereType<String>(),
        ),
        session: TokenPair.fromJson(data['session']),
      );
    }
    throw MurkioException('unknown', 0, message: 'unexpected enrollment');
  }

  /// Asks where to send the user for a social sign-in.
  Future<String> authorizeOAuth(
    String provider, {
    required String redirectUrl,
    required String state,
    required String codeChallenge,
  }) async {
    final response = await request(
      'POST',
      '/v1/oauth/${Uri.encodeComponent(provider)}/authorize',
      body: {
        'redirect_url': redirectUrl,
        'state': state,
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
      },
    );
    final data = response.data;
    if (data is Map && data['authorization_url'] is String) {
      return data['authorization_url'] as String;
    }
    throw MurkioException('unknown', 0, message: 'unexpected authorization');
  }

  Future<LoginResult> exchangeOAuthCode({
    required String code,
    required String codeVerifier,
  }) async {
    final response = await request(
      'POST',
      '/v1/oauth/token',
      body: {'code': code, 'code_verifier': codeVerifier},
    );
    return LoginResult.fromJson(response.data);
  }

  /// Closes the HTTP client, unless the app passed its own.
  void close() {
    if (_ownsHttp) _http.close();
  }
}
