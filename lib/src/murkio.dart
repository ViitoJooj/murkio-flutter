import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'crypto.dart';
import 'errors.dart';
import 'i18n.dart';
import 'models.dart';
import 'session.dart';
import 'storage.dart';

/// Opens a URL outside the app (the system browser). Returns false when
/// nothing could open it.
typedef MurkioUrlOpener = Future<bool> Function(Uri url);

/// A 2FA challenge left by a social sign-in return, for the sign-in screen
/// to continue.
class PendingMfa {
  const PendingMfa({required this.mfa, required this.keepLogged});

  final MfaChallenge mfa;
  final bool keepLogged;
}

class _CachedBootstrap {
  const _CachedBootstrap(this.etag, this.data, this.at);

  final String? etag;
  final ClientBootstrap data;
  final DateTime at;
}

class _CachedUser {
  const _CachedUser(this.sessionId, this.at, this.value);

  final String sessionId;
  final DateTime at;
  final Future<MurkioUser> value;
}

class _Signal extends ChangeNotifier {
  void fire() => notifyListeners();
}

const Duration _bootstrapTtl = Duration(seconds: 60);
const Duration _userTtl = Duration(seconds: 60);

Future<bool> _launch(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// Murkio is the client of one application. Create it once with
/// [Murkio.initialize]; the widgets all use that instance.
///
/// ```dart
/// Future<void> main() async {
///   await Murkio.initialize(publishableKey: 'pk_...');
///   runApp(const MyApp());
/// }
/// ```
class Murkio {
  /// Creates a client without making it the app's one. Call [start] before
  /// using it. Apps normally call [Murkio.initialize] instead.
  Murkio({
    required this.publishableKey,
    String? apiUrl,
    String? locale,
    this.oauthRedirectUrl,
    MurkioStorage? storage,
    http.Client? httpClient,
    MurkioUrlOpener? openUrl,
    DateTime Function()? now,
    this.observeLifecycle = true,
  }) : _localeOption = locale,
       _storage = storage ?? MurkioSecureStorage(),
       _openUrl = openUrl ?? _launch,
       _now = now ?? DateTime.now,
       keyHash = fnv1a32(publishableKey),
       api = ApiClient(
         publishableKey: publishableKey,
         apiUrl: apiUrl,
         httpClient: httpClient,
       ) {
    if (!publishableKey.startsWith('pk_')) {
      throw ArgumentError.value(
        publishableKey.startsWith('sk_') ? 'sk_...' : publishableKey,
        'publishableKey',
        'must be a publishable key (pk_...). Never put a secret key (sk_) '
            'in an app.',
      );
    }
    sessionManager = SessionManager(
      api: api,
      storage: _storage,
      keyHash: keyHash,
      now: _now,
      isForeground: _isForeground,
    );
  }

  static Murkio? _instance;

  /// The app's client. Throws until [Murkio.initialize] ran.
  static Murkio get instance {
    final instance = _instance;
    if (instance == null) {
      throw StateError(
        'Murkio is not initialized. Call `await Murkio.initialize('
        "publishableKey: 'pk_...')` in main() before runApp().",
      );
    }
    return instance;
  }

  static bool get isInitialized => _instance != null;

  /// Creates the app's client and restores the session of the last run.
  /// Calling it again with the same key returns the same client.
  ///
  /// - [publishableKey]: the application's `pk_...` key, the only required
  ///   setting.
  /// - [locale]: language of the built-in screens and error messages.
  ///   Defaults to the app's locale, then the device's.
  /// - [oauthRedirectUrl]: the https App Link / Universal Link the social
  ///   sign-in comes back to. Without it the social buttons are hidden.
  static Future<Murkio> initialize({
    required String publishableKey,
    String? apiUrl,
    String? locale,
    String? oauthRedirectUrl,
    MurkioStorage? storage,
    http.Client? httpClient,
    MurkioUrlOpener? openUrl,
  }) async {
    final existing = _instance;
    if (existing != null) {
      if (existing.publishableKey == publishableKey) return existing;
      existing.dispose();
    }
    final murkio = Murkio(
      publishableKey: publishableKey,
      apiUrl: apiUrl,
      locale: locale,
      oauthRedirectUrl: oauthRedirectUrl,
      storage: storage,
      httpClient: httpClient,
      openUrl: openUrl,
    );
    _instance = murkio;
    await murkio.start();
    return murkio;
  }

  /// For tests: forgets the app's client.
  static void reset() {
    _instance?.dispose();
    _instance = null;
  }

  final String publishableKey;

  /// The https link a social sign-in comes back to, registered in the
  /// application's redirect URLs.
  final String? oauthRedirectUrl;

  /// False keeps the client from watching the app's lifecycle (it then does
  /// not need the Flutter binding).
  final bool observeLifecycle;

  /// The hash of the publishable key that names the storage records.
  final String keyHash;

  /// The API client, for calls the SDK does not wrap.
  final ApiClient api;

  /// The session store. Most apps only need [session], [getToken] and
  /// [signOut].
  late final SessionManager sessionManager;

  final String? _localeOption;
  final MurkioStorage _storage;
  final MurkioUrlOpener _openUrl;
  final DateTime Function() _now;
  final _Signal _oauthReturn = _Signal();
  Future<void>? _starting;
  AppLifecycleListener? _lifecycle;
  _CachedBootstrap? _bootstrap;
  Future<ClientBootstrap>? _bootstrapping;
  _CachedUser? _user;
  PendingMfa? _pendingMfa;
  MurkioException? _oauthError;
  bool _disposed = false;

  /// The locale option given at creation, if any.
  String? get localeOption => _localeOption;

  /// The language the SDK speaks to the API (emails) and, unless a widget
  /// says otherwise, on the built-in screens.
  String get locale => normalizeLocale(
    _localeOption ?? PlatformDispatcher.instance.locale.toLanguageTag(),
  );

  /// True when the app configured where a social sign-in comes back to.
  bool get oauthEnabled => oauthRedirectUrl != null;

  /// The signed-in session, or null. Listen to it to follow sign-ins and
  /// sign-outs (or use `MurkioAuthBuilder`).
  ValueListenable<MurkioSession?> get session => sessionManager.listenable;

  MurkioSession? get currentSession => sessionManager.current;

  bool get isSignedIn => sessionManager.isSignedIn;

  /// Fires when a social sign-in came back and left something for the
  /// sign-in screen: see [takePendingMfa] and [takeOAuthError].
  Listenable get oauthReturn => _oauthReturn;

  /// Restores the session of the last run. [Murkio.initialize] calls it.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (observeLifecycle) {
      WidgetsFlutterBinding.ensureInitialized();
      _lifecycle = AppLifecycleListener(
        onResume: () => unawaited(sessionManager.refreshIfDue()),
      );
    }
    await sessionManager.start();
  }

  bool _isForeground() {
    if (!observeLifecycle) return true;
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// A valid access token for calling your own API, or null. Refreshes it
  /// when needed.
  Future<String?> getToken() => sessionManager.getToken();

  /// The signed-in user's profile (email, roles, 2FA), cached for a minute
  /// per session.
  Future<MurkioUser?> getUser() async {
    final token = await getToken();
    final sessionId = currentSession?.sessionId;
    if (token == null || sessionId == null) return null;
    var cached = _user;
    if (cached == null ||
        cached.sessionId != sessionId ||
        _now().difference(cached.at) > _userTtl) {
      final entry = cached = _CachedUser(sessionId, _now(), api.me(token));
      _user = entry;
      unawaited(
        entry.value.then<void>(
          (_) {},
          onError: (Object _) {
            if (identical(_user, entry)) _user = null;
          },
        ),
      );
    }
    return cached.value;
  }

  Future<void> signOut() async {
    _user = null;
    await sessionManager.signOut();
  }

  /// The application id, its public config and the published canvas. It is
  /// fetched once, kept for a minute and then revalidated with its ETag, so
  /// most calls cost a 304 at most.
  Future<ClientBootstrap> bootstrap() {
    final cached = _bootstrap;
    if (cached != null && _now().difference(cached.at) < _bootstrapTtl) {
      return SynchronousFuture(cached.data);
    }
    return _bootstrapping ??= _loadBootstrap(
      cached,
    ).whenComplete(() => _bootstrapping = null);
  }

  Future<ClientBootstrap> _loadBootstrap(_CachedBootstrap? cached) async {
    try {
      final response = await api.bootstrap(etag: cached?.etag);
      final data =
          response.notModified && cached != null ? cached.data : response.data;
      if (data == null) {
        throw MurkioException('unknown', 0, message: 'empty bootstrap');
      }
      _bootstrap = _CachedBootstrap(
        response.etag ?? cached?.etag,
        data,
        _now(),
      );
      return data;
    } on MurkioException catch (error) {
      _reportSetupError(error);
      if (cached != null) return cached.data;
      rethrow;
    }
  }

  void _reportSetupError(MurkioException error) {
    const hints = {
      'bss-01': 'the publishable key is invalid, revoked or expired.',
      'bss-10':
          'the request carried an Origin that is not allowed for this '
          'publishable key.',
    };
    final hint =
        error.code == 'network'
            ? 'could not reach ${api.apiUrl}. Check apiUrl and the connection.'
            : hints[error.code] ??
                'could not load the application (${error.code}).';
    debugPrint('[murkio] $hint');
  }

  /// Starts a social sign-in: the system browser opens the provider, which
  /// comes back to [oauthRedirectUrl]. Give that link to [handleRedirect].
  Future<void> startOAuth(String provider, {required bool keepLogged}) async {
    final redirect = oauthRedirectUrl;
    if (redirect == null) {
      throw MurkioException(
        'oauth.provider_disabled',
        0,
        message: 'oauthRedirectUrl is not configured',
      );
    }
    final verifier = randomString(64);
    final state = randomString(32);
    final url = Uri.tryParse(
      await api.authorizeOAuth(
        provider,
        redirectUrl: redirect,
        state: state,
        codeChallenge: codeChallenge(verifier),
      ),
    );
    if (url == null || url.scheme != 'https') {
      throw MurkioException(
        'oauth.server_error',
        0,
        message: 'unexpected authorization url',
      );
    }
    await _storage.write(
      _oauthKey,
      jsonEncode({
        'verifier': verifier,
        'state': state,
        'keepLogged': keepLogged,
      }),
    );
    if (!await _openUrl(url)) {
      await _storage.delete(_oauthKey);
      throw MurkioException(
        'oauth.server_error',
        0,
        message: 'could not open the browser',
      );
    }
  }

  /// Finishes a social sign-in with the link the app was opened with.
  /// Returns false when the link is not the answer to a sign-in this app
  /// started (so the app can handle it as any other deep link).
  Future<bool> handleRedirect(Uri link) async {
    final state = link.queryParameters['state'];
    if (state == null || state.isEmpty) return false;

    Object? attempt;
    try {
      final raw = await _storage.read(_oauthKey);
      attempt = raw == null ? null : jsonDecode(raw);
    } catch (_) {
      attempt = null;
    }
    if (attempt is! Map ||
        attempt['state'] != state ||
        attempt['verifier'] is! String) {
      return false;
    }
    await _storage.delete(_oauthKey);
    final keepLogged = attempt['keepLogged'] == true;

    try {
      final error = link.queryParameters['error'];
      final code = link.queryParameters['code'];
      if (error != null || code == null) {
        throw MurkioException('oauth.${error ?? 'server_error'}', 0);
      }
      final result = await api.exchangeOAuthCode(
        code: code,
        codeVerifier: attempt['verifier'] as String,
      );
      switch (result) {
        case LoginSession(:final tokens):
          await sessionManager.setSession(tokens, keepLogged: keepLogged);
        case LoginMfa(:final mfa):
          _pendingMfa = PendingMfa(mfa: mfa, keepLogged: keepLogged);
          _oauthReturn.fire();
      }
    } catch (error) {
      _oauthError = MurkioException.from(error);
      _oauthReturn.fire();
    }
    return true;
  }

  /// The 2FA challenge left by a social sign-in return, once.
  PendingMfa? takePendingMfa() {
    final pending = _pendingMfa;
    _pendingMfa = null;
    return pending;
  }

  /// The error of a social sign-in return, once.
  MurkioException? takeOAuthError() {
    final error = _oauthError;
    _oauthError = null;
    return error;
  }

  /// Opens a link outside the app (the system browser, or the authenticator
  /// app for an `otpauth://` link).
  Future<bool> openUrl(Uri url) async {
    try {
      return await _openUrl(url);
    } catch (_) {
      return false;
    }
  }

  String get _oauthKey => 'murkio.$keyHash.oauth';

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lifecycle?.dispose();
    _lifecycle = null;
    sessionManager.dispose();
    _oauthReturn.dispose();
    api.close();
  }
}

/// An HTTP client for your own API: it adds `Authorization: Bearer <access
/// token>` to every request, refreshing the token when needed.
///
/// ```dart
/// final client = MurkioHttpClient();
/// final response = await client.get(Uri.parse('https://api.example.com/me'));
/// ```
class MurkioHttpClient extends http.BaseClient {
  MurkioHttpClient({Murkio? murkio, http.Client? inner})
    : _murkio = murkio,
      _inner = inner ?? http.Client();

  final Murkio? _murkio;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final token = await (_murkio ?? Murkio.instance).getToken();
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
