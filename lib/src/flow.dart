import 'package:flutter/foundation.dart';

import 'errors.dart';
import 'models.dart';
import 'murkio.dart';

/// Where the user is in the sign-in.
sealed class FlowStep {
  const FlowStep();

  /// The name of the step, the same in every Murkio SDK.
  String get name;
}

/// The sign-in (or sign-up) screen: the canvas, or the app's own form.
class SignInStep extends FlowStep {
  const SignInStep();

  @override
  String get name => 'sign_in';
}

/// The code sent to the email. [needsPassword] is true when the SDK no
/// longer has the password the confirmation needs.
class VerifyEmailStep extends FlowStep {
  const VerifyEmailStep({required this.email, this.needsPassword = false});

  final String email;
  final bool needsPassword;

  @override
  String get name => 'verify_email';
}

/// The code of the authenticator app (or a recovery code).
class MfaStep extends FlowStep {
  const MfaStep({required this.token});

  final String token;

  @override
  String get name => 'mfa';
}

/// The application requires 2FA: the user adds [secret] to an authenticator.
class MfaEnrollStep extends FlowStep {
  const MfaEnrollStep({
    required this.token,
    required this.secret,
    required this.otpauthUri,
  });

  final String token;
  final String secret;
  final String otpauthUri;

  @override
  String get name => 'mfa_enroll';
}

/// The recovery codes to save. The session starts after the user confirms.
class RecoveryCodesStep extends FlowStep {
  const RecoveryCodesStep({required this.codes});

  final List<String> codes;

  @override
  String get name => 'recovery_codes';
}

/// "Forgot password": asks for the email.
class ForgotStep extends FlowStep {
  const ForgotStep();

  @override
  String get name => 'forgot';
}

/// The code sent to [email] and the new password.
class ResetStep extends FlowStep {
  const ResetStep({required this.email});

  final String email;

  @override
  String get name => 'reset';
}

/// The session is stored: the user is signed in.
class DoneStep extends FlowStep {
  const DoneStep();

  @override
  String get name => 'done';
}

/// What a sign-in screen draws: the step, whether a request is running, the
/// error of the last action and a notice (the key of a built-in string, see
/// `murkioString`).
@immutable
class FlowState {
  const FlowState({
    this.step = const SignInStep(),
    this.busy = false,
    this.error,
    this.notice,
  });

  final FlowStep step;
  final bool busy;
  final MurkioException? error;
  final String? notice;

  /// True for the steps a built-in screen draws (everything between the
  /// sign-in screen and the session).
  bool get inStep => step is! SignInStep && step is! DoneStep;
}

/// What the user typed on the sign-in screen.
class MurkioCredentials {
  const MurkioCredentials({
    required this.email,
    required this.password,
    this.keepLogged = false,
  });

  final String email;
  final String password;
  final bool keepLogged;
}

String _normalizeEmail(String email) => email.trim().toLowerCase();

/// FlowController walks a user through signing in: the password login, the
/// signup and its email code, the 2FA challenge (and the forced enrollment),
/// the password reset and the social sign-in. The canvas and the standalone
/// widgets draw its [state]; it holds the password only in memory, between
/// the signup and the email code, because the confirmation needs it.
class FlowController extends ChangeNotifier {
  FlowController(this.murkio) {
    murkio.oauthReturn.addListener(_takeOAuthReturn);
    _takeOAuthReturn();
  }

  final Murkio murkio;
  FlowState _state = const FlowState();
  String _email = '';
  String _password = '';
  bool _keepLogged = false;
  TokenPair? _pendingSession;
  bool _disposed = false;

  FlowState get state => _state;

  /// The email of the attempt in course, normalized.
  String get currentEmail => _email;

  Future<void> login(MurkioCredentials credentials) => _run(() async {
    _remember(credentials);
    try {
      await _handle(await murkio.api.login(email: _email, password: _password));
    } on MurkioException catch (error) {
      if (error.code != 'rsb-07') rethrow;
      await murkio.api.sendVerification(email: _email, locale: murkio.locale);
      _go(VerifyEmailStep(email: _email));
    }
  });

  Future<void> register(MurkioCredentials credentials) => _run(() async {
    _remember(credentials);
    await murkio.api.signup(
      email: _email,
      password: _password,
      locale: murkio.locale,
    );
    _go(VerifyEmailStep(email: _email));
  });

  Future<void> confirmEmail(String code, [String? password]) => _run(() async {
    if (password != null && password.isNotEmpty) _password = password;
    if (_password.isEmpty) {
      _go(VerifyEmailStep(email: _email, needsPassword: true));
      return;
    }
    final result = await murkio.api.confirmVerification(
      email: _email,
      code: code.trim(),
      password: _password,
    );
    if (result != null) {
      await _handle(result);
      return;
    }
    _password = '';
    _go(const SignInStep(), notice: 'verified.signin');
  });

  Future<void> resendEmail() => _run(() async {
    await murkio.api.sendVerification(email: _email, locale: murkio.locale);
    _set(notice: 'verify.resent');
  });

  Future<void> verifyMfa(String code) => _run(() async {
    final step = _state.step;
    if (step is! MfaStep) return;
    await _complete(
      await murkio.api.verifyMfa(mfaToken: step.token, code: code.trim()),
    );
  });

  Future<void> confirmEnrollment(String code) => _run(() async {
    final step = _state.step;
    if (step is! MfaEnrollStep) return;
    final result = await murkio.api.confirmMfaEnrollment(
      mfaToken: step.token,
      code: code.trim(),
    );
    _pendingSession = result.session;
    _go(RecoveryCodesStep(codes: result.recoveryCodes));
  });

  /// The user saved the recovery codes: the session starts.
  Future<void> finishRecovery() => _run(() async {
    final session = _pendingSession;
    if (session != null) await _complete(session);
  });

  void forgot([String email = '']) {
    if (_state.busy) return;
    if (email.trim().isNotEmpty) _email = _normalizeEmail(email);
    _go(const ForgotStep());
  }

  Future<void> requestReset(String email) => _run(() async {
    _email = _normalizeEmail(email);
    await murkio.api.requestPasswordReset(email: _email, locale: murkio.locale);
    _go(ResetStep(email: _email));
  });

  Future<void> resetPassword(String code, String password) => _run(() async {
    await murkio.api.confirmPasswordReset(
      email: _email,
      code: code.trim(),
      password: password,
    );
    _go(const SignInStep(), notice: 'reset.done');
  });

  /// Starts a social sign-in: the system browser opens the provider.
  Future<void> oauth(String provider, {required bool keepLogged}) =>
      _run(() => murkio.startOAuth(provider, keepLogged: keepLogged));

  void back() {
    if (_state.busy) return;
    _password = '';
    _pendingSession = null;
    _go(const SignInStep());
  }

  @override
  void dispose() {
    _disposed = true;
    murkio.oauthReturn.removeListener(_takeOAuthReturn);
    super.dispose();
  }

  /// A social sign-in came back to the app: it either left a 2FA challenge
  /// for this screen to continue, or an error to show.
  void _takeOAuthReturn() {
    final pending = murkio.takePendingMfa();
    if (pending != null) {
      _keepLogged = pending.keepLogged;
      _run(() => _challenge(pending.mfa));
      return;
    }
    final error = murkio.takeOAuthError();
    if (error != null) _set(error: error);
  }

  void _remember(MurkioCredentials credentials) {
    _email = _normalizeEmail(credentials.email);
    _password = credentials.password;
    _keepLogged = credentials.keepLogged;
  }

  Future<void> _handle(LoginResult result) async {
    switch (result) {
      case LoginSession(:final tokens):
        await _complete(tokens);
      case LoginMfa(:final mfa):
        await _challenge(mfa);
    }
  }

  Future<void> _challenge(MfaChallenge mfa) async {
    if (!mfa.enrollmentRequired) {
      _go(MfaStep(token: mfa.token));
      return;
    }
    final enrollment = await murkio.api.startMfaEnrollment(mfaToken: mfa.token);
    _go(
      MfaEnrollStep(
        token: mfa.token,
        secret: enrollment.secret,
        otpauthUri: enrollment.otpauthUri,
      ),
    );
  }

  Future<void> _complete(TokenPair tokens) async {
    await murkio.sessionManager.setSession(tokens, keepLogged: _keepLogged);
    _password = '';
    _pendingSession = null;
    _go(const DoneStep());
  }

  void _go(FlowStep step, {String? notice}) {
    _state = FlowState(step: step, busy: _state.busy, notice: notice);
    _notify();
  }

  void _set({bool? busy, MurkioException? error, String? notice}) {
    _state = FlowState(
      step: _state.step,
      busy: busy ?? _state.busy,
      error: error,
      notice: notice,
    );
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_state.busy) return;
    _state = FlowState(step: _state.step, busy: true);
    _notify();
    try {
      await task();
    } catch (error) {
      _state = FlowState(
        step: _state.step,
        busy: true,
        error: MurkioException.from(error),
      );
    } finally {
      _state = FlowState(
        step: _state.step,
        busy: false,
        error: _state.error,
        notice: _state.notice,
      );
      _notify();
    }
  }
}
