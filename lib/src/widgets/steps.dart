import 'package:flutter/material.dart';

import '../canvas/model.dart';
import '../errors.dart';
import '../flow.dart';
import '../i18n.dart';
import 'controls.dart';
import 'look.dart';

/// Draws the built-in screen of a flow step (email code, two-step
/// verification, enrollment, recovery codes, password reset) with the canvas
/// theme. The customer only designs the sign-in (and sign-up) screen; these
/// follow its colors and font.
class MurkioStepView extends StatefulWidget {
  const MurkioStepView({
    super.key,
    required this.flow,
    required this.theme,
    required this.locale,
    required this.onOpenUrl,
  });

  final FlowController flow;
  final CanvasTheme theme;
  final String locale;

  /// Opens the authenticator app with the `otpauth://` link.
  final void Function(Uri url) onOpenUrl;

  @override
  State<MurkioStepView> createState() => _MurkioStepViewState();
}

class _MurkioStepViewState extends State<MurkioStepView> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final FocusNode _first = FocusNode();
  final FocusNode _second = FocusNode();
  FlowStep? _step;

  @override
  void initState() {
    super.initState();
    widget.flow.addListener(_changed);
    _enter(widget.flow.state.step);
  }

  @override
  void didUpdateWidget(MurkioStepView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flow != widget.flow) {
      oldWidget.flow.removeListener(_changed);
      widget.flow.addListener(_changed);
      _enter(widget.flow.state.step);
    }
  }

  @override
  void dispose() {
    widget.flow.removeListener(_changed);
    _code.dispose();
    _password.dispose();
    _email.dispose();
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() => _enter(widget.flow.state.step));
  }

  /// A new step starts with empty fields and the focus on the first one.
  void _enter(FlowStep step) {
    if (identical(step, _step)) return;
    final sameScreen = _step?.name == step.name;
    _step = step;
    if (sameScreen) return;
    _code.clear();
    _password.clear();
    _email.text = step is ForgotStep ? widget.flow.currentEmail : '';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && step is! RecoveryCodesStep) _first.requestFocus();
    });
  }

  String _say(String key, [Map<String, String> params = const {}]) =>
      murkioString(widget.locale, key, params);

  @override
  Widget build(BuildContext context) {
    final flow = widget.flow;
    final state = flow.state;
    final step = state.step;
    final theme = widget.theme;
    final base = themeTextStyle(theme, context);
    final textColor = Color(theme.text);
    final muted = Color(theme.muted);

    final children = <Widget>[];
    void heading(
      String title,
      String description, [
      Map<String, String> params = const {},
    ]) {
      children.add(
        Semantics(
          header: true,
          child: Text(
            _say(title),
            style: base.copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
        ),
      );
      children.add(
        Text(
          _say(description, params),
          style: base.copyWith(fontSize: 16, color: muted),
        ),
      );
    }

    Widget field(
      String label,
      TextEditingController controller, {
      FocusNode? focusNode,
      bool obscure = false,
      TextInputType keyboardType = TextInputType.text,
      List<String> hints = const [],
      TextInputAction action = TextInputAction.done,
      VoidCallback? onSubmitted,
    }) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: MurkioTextField(
          look: ElementLook(
            foreground: textColor,
            fontSize: 16,
            background: Color(theme.surface),
            borderColor: Color(theme.border),
            borderWidth: 1,
            radius: theme.radius.toDouble(),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          textStyle: base,
          label: label,
          hint: label,
          hintColor: muted,
          accent: Color(theme.primary),
          controller: controller,
          focusNode: focusNode,
          obscure: obscure,
          keyboardType: keyboardType,
          autofillHints: hints,
          action: action,
          onSubmitted: onSubmitted,
        ),
      );
    }

    Widget primary(String label, VoidCallback onTap) => SizedBox(
      height: 44,
      child: MurkioButton(
        label: label,
        look: ElementLook(
          foreground: Color(theme.onPrimary),
          fontSize: 16,
          background: Color(theme.primary),
          radius: theme.radius.toDouble(),
          weight: FontWeight.w600,
          align: TextAlign.center,
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        textStyle: base,
        onTap: onTap,
        busy: state.busy,
      ),
    );

    Widget link(String label, VoidCallback onTap) => ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: MurkioButton(
        label: label,
        look: ElementLook(
          foreground: Color(theme.primary),
          fontSize: 14,
          align: TextAlign.center,
        ),
        textStyle: base,
        onTap: onTap,
        busy: state.busy,
        underline: true,
      ),
    );

    final controls = <Widget>[];
    switch (step) {
      case VerifyEmailStep():
        heading('verify.title', 'verify.description', {'email': step.email});
        void submit() => flow.confirmEmail(
          _code.text,
          step.needsPassword ? _password.text : null,
        );
        children.add(
          field(
            _say('verify.code'),
            _code,
            focusNode: _first,
            hints: const [AutofillHints.oneTimeCode],
            action: step.needsPassword
                ? TextInputAction.next
                : TextInputAction.done,
            onSubmitted: step.needsPassword ? _second.requestFocus : submit,
          ),
        );
        if (step.needsPassword) {
          children.add(
            field(
              _say('verify.password'),
              _password,
              focusNode: _second,
              obscure: true,
              hints: const [AutofillHints.password],
              onSubmitted: submit,
            ),
          );
        }
        controls
          ..add(primary(_say('verify.submit'), submit))
          ..add(link(_say('verify.resend'), flow.resendEmail));
      case MfaStep():
        heading('mfa.title', 'mfa.description');
        void submit() => flow.verifyMfa(_code.text);
        children.add(
          field(
            _say('mfa.code'),
            _code,
            focusNode: _first,
            hints: const [AutofillHints.oneTimeCode],
            onSubmitted: submit,
          ),
        );
        controls.add(primary(_say('mfa.submit'), submit));
      case MfaEnrollStep():
        heading('enroll.title', 'enroll.description');
        void submit() => flow.confirmEnrollment(_code.text);
        children.add(
          Text.rich(
            TextSpan(
              text: '${_say('enroll.secret')}: ',
              style: base.copyWith(fontSize: 16, color: muted),
              children: [
                TextSpan(
                  text: step.secret,
                  style: monoTextStyle.copyWith(fontSize: 15, color: textColor),
                ),
              ],
            ),
          ),
        );
        final uri = Uri.tryParse(step.otpauthUri);
        if (uri != null && uri.scheme == 'otpauth') {
          children.add(link(_say('enroll.open'), () => widget.onOpenUrl(uri)));
        }
        children.add(
          field(
            _say('enroll.code'),
            _code,
            focusNode: _first,
            hints: const [AutofillHints.oneTimeCode],
            onSubmitted: submit,
          ),
        );
        controls.add(primary(_say('enroll.submit'), submit));
      case RecoveryCodesStep():
        heading('recovery.title', 'recovery.description');
        children.add(
          SelectableText(
            [
              for (var i = 0; i < step.codes.length; i++)
                '${i + 1}. ${step.codes[i]}',
            ].join('\n'),
            style: monoTextStyle.copyWith(
              fontSize: 15,
              height: 1.6,
              color: textColor,
            ),
          ),
        );
        controls.add(primary(_say('recovery.done'), flow.finishRecovery));
      case ForgotStep():
        heading('forgot.title', 'forgot.description');
        void submit() => flow.requestReset(_email.text);
        children.add(
          field(
            _say('forgot.email'),
            _email,
            focusNode: _first,
            keyboardType: TextInputType.emailAddress,
            hints: const [AutofillHints.username, AutofillHints.email],
            onSubmitted: submit,
          ),
        );
        controls.add(primary(_say('forgot.submit'), submit));
      case ResetStep():
        heading('reset.title', 'reset.description', {'email': step.email});
        void submit() => flow.resetPassword(_code.text, _password.text);
        children
          ..add(
            field(
              _say('reset.code'),
              _code,
              focusNode: _first,
              hints: const [AutofillHints.oneTimeCode],
              action: TextInputAction.next,
              onSubmitted: _second.requestFocus,
            ),
          )
          ..add(
            field(
              _say('reset.password'),
              _password,
              focusNode: _second,
              obscure: true,
              hints: const [AutofillHints.newPassword],
              onSubmitted: submit,
            ),
          );
        controls.add(primary(_say('reset.submit'), submit));
      case SignInStep():
      case DoneStep():
        return const SizedBox.shrink();
    }

    final error = state.error;
    final message = error != null
        ? translateError(error.code, widget.locale)
        : state.notice != null
        ? _say(state.notice!)
        : null;
    if (message != null) {
      children.add(
        Semantics(
          liveRegion: true,
          child: Text(
            message,
            key: const ValueKey('murkio-step-message'),
            style: base.copyWith(
              fontSize: 14,
              color: error != null ? Color(theme.error) : textColor,
            ),
          ),
        ),
      );
    }

    if (step is! RecoveryCodesStep) controls.add(link(_say('back'), flow.back));
    children.addAll(controls);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: ColoredBox(
          key: ValueKey('murkio-step-${step.name}'),
          color: Color(theme.background),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: AutofillGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const SizedBox(height: 12),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
