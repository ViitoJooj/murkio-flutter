import 'dart:convert';

import 'errors.dart';

/// The tokens of a session, as the API returns them.
class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.sessionId,
  });

  /// Reads a token pair; anything else is an `unknown` error.
  factory TokenPair.fromJson(Object? json) {
    if (json is Map &&
        json['access_token'] is String &&
        json['refresh_token'] is String &&
        json['expires_in'] is num &&
        json['session_id'] is String) {
      return TokenPair(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        expiresIn: (json['expires_in'] as num).toInt(),
        sessionId: json['session_id'] as String,
      );
    }
    throw MurkioException('unknown', 0, message: 'unexpected token response');
  }

  final String accessToken;
  final String refreshToken;

  /// Seconds until the access token expires.
  final int expiresIn;
  final String sessionId;
}

/// The two-step verification the API asks for before giving a session.
class MfaChallenge {
  const MfaChallenge({required this.token, required this.enrollmentRequired});

  final String token;

  /// The application requires 2FA and the user has no authenticator yet.
  final bool enrollmentRequired;
}

/// What a sign-in returns: a session, or the 2FA challenge to pass first.
sealed class LoginResult {
  const LoginResult();

  factory LoginResult.fromJson(Object? json) {
    if (json is Map && json['mfa'] is Map) {
      final mfa = json['mfa'] as Map;
      if (mfa['token'] is String) {
        return LoginMfa(
          MfaChallenge(
            token: mfa['token'] as String,
            enrollmentRequired: mfa['enrollment_required'] == true,
          ),
        );
      }
    }
    return LoginSession(TokenPair.fromJson(json));
  }
}

class LoginSession extends LoginResult {
  const LoginSession(this.tokens);

  final TokenPair tokens;
}

class LoginMfa extends LoginResult {
  const LoginMfa(this.mfa);

  final MfaChallenge mfa;
}

/// The signed-in user's profile (`POST /v1/me`).
class MurkioUser {
  const MurkioUser({
    required this.id,
    required this.sessionId,
    required this.email,
    required this.emailVerified,
    required this.roles,
    required this.mfaEnabled,
    required this.createdAt,
  });

  factory MurkioUser.fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) {
      throw MurkioException('unknown', 0, message: 'unexpected profile');
    }
    return MurkioUser(
      id: json['id'] as String,
      sessionId:
          json['session_id'] is String ? json['session_id'] as String : '',
      email: json['email'] is String ? json['email'] as String : null,
      emailVerified: json['email_verified'] == true,
      roles: _strings(json['roles']),
      mfaEnabled: json['mfa_enabled'] == true,
      createdAt:
          json['created_at'] is String
              ? DateTime.tryParse(json['created_at'] as String)
              : null,
    );
  }

  final String id;
  final String sessionId;

  /// Null for a user that only has a social sign-in without an email.
  final String? email;
  final bool emailVerified;
  final List<String> roles;
  final bool mfaEnabled;
  final DateTime? createdAt;
}

/// What the application turned on, as the login screen needs to know.
class PublicConfig {
  const PublicConfig({
    this.passwordEnabled = true,
    this.mfaMode = 'optional',
    this.oauthProviders = const [],
    this.loginOnVerify = true,
  });

  factory PublicConfig.fromJson(Object? json) {
    if (json is! Map) return const PublicConfig();
    final methods = json['methods'];
    final mfa = json['mfa'];
    final signup = json['signup'];
    return PublicConfig(
      passwordEnabled: methods is Map ? methods['password'] != false : true,
      mfaMode:
          mfa is Map && mfa['mode'] is String ? mfa['mode'] as String : 'off',
      oauthProviders: _strings(json['oauth_providers']),
      loginOnVerify: signup is Map ? signup['login_on_verify'] != false : true,
    );
  }

  final bool passwordEnabled;

  /// `off`, `optional` or `required`.
  final String mfaMode;
  final List<String> oauthProviders;
  final bool loginOnVerify;
}

/// The answer of `GET /v1/client`: the application behind the publishable
/// key, its public config and the published canvas.
class ClientBootstrap {
  const ClientBootstrap({
    required this.applicationId,
    required this.config,
    required this.canvasVersion,
    required this.canvasDocument,
  });

  factory ClientBootstrap.fromJson(Object? json) {
    if (json is! Map ||
        json['application_id'] is! String ||
        json['canvas'] is! Map) {
      throw MurkioException('unknown', 0, message: 'unexpected bootstrap');
    }
    final canvas = json['canvas'] as Map;
    return ClientBootstrap(
      applicationId: json['application_id'] as String,
      config: PublicConfig.fromJson(json['config']),
      canvasVersion:
          canvas['version'] is num ? (canvas['version'] as num).toInt() : 0,
      canvasDocument: canvas['document'],
    );
  }

  final String applicationId;
  final PublicConfig config;

  /// 0 is the default canvas: the application never published one.
  final int canvasVersion;

  /// The canvas as it came from the API. It is validated again before it is
  /// drawn (see `sanitizeDocument`).
  final Object? canvasDocument;
}

/// The claims of an access token the app may want to read.
class AccessClaims {
  const AccessClaims({
    required this.subject,
    required this.sessionId,
    required this.expiresAt,
    required this.roles,
  });

  /// The user id.
  final String subject;
  final String sessionId;
  final DateTime expiresAt;
  final List<String> roles;
}

/// Reads the claims of an access token **without checking its signature**.
/// The app only uses them for display and timing; every decision that matters
/// is taken by the API or by a backend that verifies the token.
AccessClaims? decodeClaims(String token) {
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final Object? claims = jsonDecode(payload);
    if (claims is! Map || claims['exp'] is! num || claims['sub'] is! String) {
      return null;
    }
    return AccessClaims(
      subject: claims['sub'] as String,
      sessionId: claims['sid'] is String ? claims['sid'] as String : '',
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        ((claims['exp'] as num) * 1000).round(),
        isUtc: true,
      ),
      roles: _strings(claims['roles']),
    );
  } on FormatException {
    return null;
  }
}

List<String> _strings(Object? value) =>
    value is List
        ? List.unmodifiable(value.whereType<String>())
        : const <String>[];
