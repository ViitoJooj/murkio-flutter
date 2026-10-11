import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../canvas/model.dart';
import '../canvas/validate.dart';
import '../errors.dart';
import '../flow.dart';
import '../i18n.dart';
import '../murkio.dart';
import '../session.dart';
import 'environment.dart';
import 'steps.dart';

/// MurkioFormController joins the standalone widgets of one form: the inputs
/// write the values, the buttons run the flow with them, and the built-in
/// screens (email code, two-step verification, password reset) open in a
/// dialog painted with the application's canvas theme.
///
/// Widgets outside a [MurkioIdentityForm] share the default controller of
/// the Murkio client, so most apps never create one.
class MurkioFormController extends ChangeNotifier {
  MurkioFormController({Murkio? murkio}) : _murkioOption = murkio;

  static final Expando<MurkioFormController> _defaults = Expando();

  /// The controller shared by every widget that is not inside a
  /// [MurkioIdentityForm].
  static MurkioFormController shared([Murkio? murkio]) {
    final client = murkio ?? Murkio.instance;
    return _defaults[client] ??= MurkioFormController(murkio: client);
  }

  final Murkio? _murkioOption;
  FlowController? _flow;
  NavigatorState? _navigator;
  Route<void>? _dialog;
  CanvasTheme? _theme;
  MurkioException? _lastError;
  String _lastStep = 'sign_in';
  int _keepLoggedWidgets = 0;
  bool _keepLogged = false;

  String email = '';
  String password = '';

  /// Called when the user is signed in.
  ValueChanged<MurkioSession>? onLogin;

  /// Called when an action fails.
  ValueChanged<MurkioException>? onError;

  Murkio get murkio => _murkioOption ?? Murkio.instance;

  /// The flow's state: what the buttons and the error widget draw.
  FlowState get state => _flow?.state ?? const FlowState();

  /// "Keep me signed in". Without a [MurkioIdentityKeepLogged] in the form
  /// the session is kept: that is what a user expects from an app.
  bool get keepLogged => _keepLoggedWidgets == 0 ? true : _keepLogged;

  set keepLogged(bool value) {
    if (_keepLogged == value) return;
    _keepLogged = value;
    notifyListeners();
  }

  /// Signs in with what the inputs hold.
  Future<void> login(BuildContext context) => _run(context, register: false);

  /// Creates the account with what the inputs hold.
  Future<void> register(BuildContext context) => _run(context, register: true);

  Future<void> _run(BuildContext context, {required bool register}) async {
    _navigator = Navigator.maybeOf(context, rootNavigator: true);
    final locale = resolveLocale(
      context,
      optionLocale: murkio.localeOption,
      deviceLocale:
          WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag(),
    );
    _locale = locale;
    final flow = _flow ??= FlowController(murkio)..addListener(_changed);
    final credentials = MurkioCredentials(
      email: email,
      password: password,
      keepLogged: keepLogged,
    );
    await (register ? flow.register(credentials) : flow.login(credentials));
  }

  String _locale = 'en';

  void _changed() {
    final flow = _flow;
    if (flow == null) return;
    final state = flow.state;
    notifyListeners();

    final error = state.error;
    if (error != null && !identical(error, _lastError)) onError?.call(error);
    _lastError = error;

    if (state.inStep) {
      unawaited(_openDialog(flow));
    } else {
      _closeDialog();
    }

    final name = state.step.name;
    if (name != _lastStep) {
      _lastStep = name;
      if (state.step is DoneStep) {
        TextInput.finishAutofillContext();
        password = '';
        final session = murkio.currentSession;
        if (session != null) onLogin?.call(session);
      }
    }
  }

  Future<void> _openDialog(FlowController flow) async {
    final navigator = _navigator;
    if (_dialog != null || navigator == null || !navigator.mounted) return;

    // The route is registered before the theme loads, so a second state
    // change during the request does not open a second dialog.
    final route = DialogRoute<void>(
      context: navigator.context,
      barrierLabel: murkioString(_locale, 'back'),
      builder: (context) => _StepDialog(controller: this, flow: flow),
    );
    _dialog = route;
    unawaited(
      navigator.push(route).then((_) {
        if (identical(_dialog, route)) {
          _dialog = null;
          // Dismissed by the user (barrier or back button), not by the flow.
          if (flow.state.inStep) flow.back();
        }
      }),
    );

    if (_theme == null) {
      CanvasTheme theme;
      try {
        final bootstrap = await murkio.bootstrap();
        theme = pickCanvas(bootstrap.canvasDocument, bootstrap.config).theme;
      } on MurkioException {
        theme = defaultCanvas().theme;
      }
      _theme = theme;
      notifyListeners();
    }
  }

  void _closeDialog() {
    final route = _dialog;
    final navigator = _navigator;
    _dialog = null;
    if (route != null &&
        navigator != null &&
        navigator.mounted &&
        route.isActive) {
      navigator.removeRoute(route);
    }
  }

  @override
  void dispose() {
    _closeDialog();
    _flow?.removeListener(_changed);
    _flow?.dispose();
    super.dispose();
  }
}

class _StepDialog extends StatelessWidget {
  const _StepDialog({required this.controller, required this.flow});

  final MurkioFormController controller;
  final FlowController flow;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final theme = controller._theme;
        return Dialog(
          clipBehavior: Clip.antiAlias,
          backgroundColor: theme == null ? null : Color(theme.background),
          insetPadding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child:
                theme == null
                    ? const SizedBox(height: 120)
                    : SingleChildScrollView(
                      child: MurkioEnvironment(
                        child: MurkioStepView(
                          flow: flow,
                          theme: theme,
                          locale: controller._locale,
                          onOpenUrl: (url) => controller.murkio.openUrl(url),
                        ),
                      ),
                    ),
          ),
        );
      },
    );
  }
}

class _FormScope extends InheritedNotifier<MurkioFormController> {
  const _FormScope({
    required MurkioFormController controller,
    required super.child,
  }) : super(notifier: controller);
}

/// Gives the widgets below it their own form, apart from the app's default
/// one. Only needed for two independent forms on screen, or to receive
/// [onLogin] and [onError] in one place.
class MurkioIdentityForm extends StatefulWidget {
  const MurkioIdentityForm({
    super.key,
    required this.child,
    this.murkio,
    this.onLogin,
    this.onError,
  });

  final Widget child;
  final Murkio? murkio;
  final ValueChanged<MurkioSession>? onLogin;
  final ValueChanged<MurkioException>? onError;

  /// The form of the widgets at [context]: the nearest [MurkioIdentityForm],
  /// else the app's default form. The widget rebuilds when its state changes.
  static MurkioFormController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FormScope>()?.notifier ??
      MurkioFormController.shared();

  @override
  State<MurkioIdentityForm> createState() => _MurkioIdentityFormState();
}

class _MurkioIdentityFormState extends State<MurkioIdentityForm> {
  late final MurkioFormController _controller = MurkioFormController(
    murkio: widget.murkio,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _controller
      ..onLogin = widget.onLogin
      ..onError = widget.onError;
    return _FormScope(
      controller: _controller,
      child: AutofillGroup(child: widget.child),
    );
  }
}

/// Rebuilds with the form's state. Widgets outside a [MurkioIdentityForm]
/// listen to the shared controller themselves, since no inherited widget
/// tells them when it changes.
mixin _FormListener<T extends StatefulWidget> on State<T> {
  MurkioFormController? _form;

  MurkioFormController get form => _form!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = MurkioIdentityForm.of(context);
    if (identical(next, _form)) return;
    _form?.removeListener(_formChanged);
    _detach(_form);
    _form = next..addListener(_formChanged);
    _attach(next);
  }

  @override
  void dispose() {
    _form?.removeListener(_formChanged);
    _detach(_form);
    super.dispose();
  }

  void _formChanged() {
    if (mounted) setState(() {});
  }

  void _attach(MurkioFormController form) {}

  void _detach(MurkioFormController? form) {}
}

/// The email field of a sign-in form. It is a regular Material [TextField]:
/// style it with [decoration] and [style] like any other field of the app.
class MurkioIdentityEmailInput extends StatefulWidget {
  const MurkioIdentityEmailInput({
    super.key,
    this.decoration = const InputDecoration(),
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.textInputAction = TextInputAction.next,
  });

  final InputDecoration decoration;
  final TextStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final TextInputAction textInputAction;

  @override
  State<MurkioIdentityEmailInput> createState() =>
      _MurkioIdentityEmailInputState();
}

class _MurkioIdentityEmailInputState extends State<MurkioIdentityEmailInput>
    with _FormListener {
  final TextEditingController _controller = TextEditingController();

  @override
  void _attach(MurkioFormController form) => _controller.text = form.email;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      keyboardType: TextInputType.emailAddress,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.none,
      autofillHints: const [AutofillHints.username, AutofillHints.email],
      textInputAction: widget.textInputAction,
      decoration: widget.decoration,
      style: widget.style,
      onChanged: (value) => form.email = value,
    );
  }
}

/// The password field of a sign-in form. The keyboard's action button signs
/// in (or registers, with [newPassword]).
class MurkioIdentityPasswordInput extends StatefulWidget {
  const MurkioIdentityPasswordInput({
    super.key,
    this.decoration = const InputDecoration(),
    this.style,
    this.focusNode,
    this.obscureText = true,
    this.newPassword = false,
    this.submitOnDone = true,
  });

  final InputDecoration decoration;
  final TextStyle? style;
  final FocusNode? focusNode;
  final bool obscureText;

  /// True on a sign-up form: password managers then offer a new password,
  /// and the keyboard's action button registers instead of signing in.
  final bool newPassword;

  /// Run the form when the keyboard's action button is pressed.
  final bool submitOnDone;

  @override
  State<MurkioIdentityPasswordInput> createState() =>
      _MurkioIdentityPasswordInputState();
}

class _MurkioIdentityPasswordInputState
    extends State<MurkioIdentityPasswordInput>
    with _FormListener {
  final TextEditingController _controller = TextEditingController();

  @override
  void _attach(MurkioFormController form) => _controller.text = form.password;

  @override
  void _formChanged() {
    // The form drops the password once the user is signed in.
    if (form.password.isEmpty && _controller.text.isNotEmpty) {
      _controller.clear();
    }
    super._formChanged();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: widget.focusNode,
      obscureText: widget.obscureText,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: [
        widget.newPassword ? AutofillHints.newPassword : AutofillHints.password,
      ],
      textInputAction: TextInputAction.done,
      decoration: widget.decoration,
      style: widget.style,
      onChanged: (value) => form.password = value,
      onSubmitted: (_) {
        if (!widget.submitOnDone) return;
        widget.newPassword ? form.register(context) : form.login(context);
      },
    );
  }
}

/// The "keep me signed in" checkbox. Unchecked, the session ends when the
/// app is closed.
class MurkioIdentityKeepLogged extends StatefulWidget {
  const MurkioIdentityKeepLogged({
    super.key,
    this.label,
    this.initialValue = false,
    this.activeColor,
    this.builder,
  });

  /// The text next to the checkbox.
  final Widget? label;
  final bool initialValue;
  final Color? activeColor;

  /// Draws the control yourself (a switch, a Cupertino control...).
  final Widget Function(
    BuildContext context,
    bool value,
    ValueChanged<bool> onChanged,
  )?
  builder;

  @override
  State<MurkioIdentityKeepLogged> createState() =>
      _MurkioIdentityKeepLoggedState();
}

class _MurkioIdentityKeepLoggedState extends State<MurkioIdentityKeepLogged>
    with _FormListener {
  @override
  void _attach(MurkioFormController form) {
    if (form._keepLoggedWidgets++ == 0) form._keepLogged = widget.initialValue;
  }

  @override
  void _detach(MurkioFormController? form) {
    if (form != null) form._keepLoggedWidgets--;
  }

  @override
  Widget build(BuildContext context) {
    final value = form.keepLogged;
    void change(bool next) => form.keepLogged = next;
    final builder = widget.builder;
    if (builder != null) return builder(context, value, change);
    return MergeSemantics(
      child: InkWell(
        onTap: () => change(!value),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: value,
              activeColor: widget.activeColor,
              onChanged: (next) => change(next ?? false),
            ),
            if (widget.label != null) Flexible(child: widget.label!),
          ],
        ),
      ),
    );
  }
}

/// Draws a sign-in or register button yourself: [onPressed] is null while a
/// request runs.
typedef MurkioButtonBuilder =
    Widget Function(BuildContext context, VoidCallback? onPressed, bool busy);

abstract class _ActionButton extends StatefulWidget {
  const _ActionButton({
    super.key,
    this.child,
    this.style,
    this.builder,
    this.onLogin,
    this.onError,
  }) : assert(
         child != null || builder != null,
         'Give the button a child, or a builder to draw it yourself.',
       );

  final Widget? child;
  final ButtonStyle? style;
  final MurkioButtonBuilder? builder;

  /// The user is signed in. The same as listening to `Murkio.session`.
  final ValueChanged<MurkioSession>? onLogin;
  final ValueChanged<MurkioException>? onError;

  bool get _register;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> with _FormListener {
  void _press() {
    if (widget.onLogin != null) form.onLogin = widget.onLogin;
    if (widget.onError != null) form.onError = widget.onError;
    widget._register ? form.register(context) : form.login(context);
  }

  @override
  Widget build(BuildContext context) {
    final busy = form.state.busy;
    final onPressed = busy ? null : _press;
    final builder = widget.builder;
    if (builder != null) return builder(context, onPressed, busy);
    return widget._register
        ? OutlinedButton(
          onPressed: onPressed,
          style: widget.style,
          child: widget.child,
        )
        : FilledButton(
          onPressed: onPressed,
          style: widget.style,
          child: widget.child,
        );
  }
}

/// Signs in with the email and password of its form. A [FilledButton] by
/// default; pass [builder] for any other look.
class MurkioIdentityLoginButton extends _ActionButton {
  const MurkioIdentityLoginButton({
    super.key,
    super.child,
    super.style,
    super.builder,
    super.onLogin,
    super.onError,
  });

  @override
  bool get _register => false;
}

/// Creates the account with the email and password of its form, then asks
/// for the code sent to the email. An [OutlinedButton] by default.
class MurkioIdentityRegisterButton extends _ActionButton {
  const MurkioIdentityRegisterButton({
    super.key,
    super.child,
    super.style,
    super.builder,
    super.onLogin,
    super.onError,
  });

  @override
  bool get _register => true;
}

/// Shows the translated error (or notice) of its form. Empty when there is
/// nothing to say.
class MurkioIdentityError extends StatefulWidget {
  const MurkioIdentityError({super.key, this.style, this.locale});

  final TextStyle? style;
  final String? locale;

  @override
  State<MurkioIdentityError> createState() => _MurkioIdentityErrorState();
}

class _MurkioIdentityErrorState extends State<MurkioIdentityError>
    with _FormListener {
  @override
  Widget build(BuildContext context) {
    final state = form.state;
    if (state.inStep) return const SizedBox.shrink();
    final locale = resolveLocale(
      context,
      widgetLocale: widget.locale,
      optionLocale: form.murkio.localeOption,
      deviceLocale:
          WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag(),
    );
    final error = state.error;
    final text =
        error != null
            ? translateError(error.code, locale)
            : state.notice != null
            ? murkioString(locale, state.notice!)
            : null;
    if (text == null) return const SizedBox.shrink();
    final style =
        widget.style ??
        TextStyle(
          color: error != null ? Theme.of(context).colorScheme.error : null,
        );
    return Semantics(liveRegion: true, child: Text(text, style: style));
  }
}

/// Rebuilds when the user signs in or out (not on every token refresh).
///
/// ```dart
/// MurkioAuthBuilder(
///   builder: (context, session) =>
///       session == null ? const LoginPage() : const HomePage(),
/// )
/// ```
class MurkioAuthBuilder extends StatefulWidget {
  const MurkioAuthBuilder({super.key, required this.builder, this.murkio});

  final Widget Function(BuildContext context, MurkioSession? session) builder;
  final Murkio? murkio;

  @override
  State<MurkioAuthBuilder> createState() => _MurkioAuthBuilderState();
}

class _MurkioAuthBuilderState extends State<MurkioAuthBuilder> {
  late Murkio _murkio;
  String? _sessionId;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(MurkioAuthBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.murkio != widget.murkio) {
      _murkio.session.removeListener(_changed);
      _listen();
    }
  }

  void _listen() {
    _murkio = widget.murkio ?? Murkio.instance;
    _murkio.session.addListener(_changed);
    _sessionId = _murkio.currentSession?.sessionId;
  }

  void _changed() {
    final sessionId = _murkio.currentSession?.sessionId;
    if (sessionId == _sessionId || !mounted) return;
    setState(() => _sessionId = sessionId);
  }

  @override
  void dispose() {
    _murkio.session.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _murkio.currentSession);
}
