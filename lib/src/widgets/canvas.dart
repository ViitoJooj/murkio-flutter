import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../canvas/layout.dart';
import '../canvas/model.dart';
import '../canvas/validate.dart';
import '../errors.dart';
import '../flow.dart';
import '../i18n.dart';
import '../models.dart';
import '../murkio.dart';
import '../session.dart';
import 'controls.dart';
import 'environment.dart';
import 'look.dart';
import 'steps.dart';

/// Which screen of the canvas to draw.
enum MurkioScreen { signIn, signUp }

/// Inside the frame the boxes have a fixed size, so the device's text size
/// setting only applies up to this factor.
const double _maxTextScale = 1.3;

/// Draws the application's published login canvas and runs the whole sign-in
/// on it: signup, email code, two-step verification, password reset and
/// social sign-in.
///
/// ```dart
/// MurkioIdentityCanvas(
///   onLogin: (session) => Navigator.of(context).pushReplacementNamed('/home'),
/// )
/// ```
///
/// The canvas takes the width it is given and is as tall as its layout; put
/// it in a scroll view so the keyboard never covers it.
class MurkioIdentityCanvas extends StatefulWidget {
  const MurkioIdentityCanvas({
    super.key,
    this.murkio,
    this.screen = MurkioScreen.signIn,
    this.locale,
    this.onLogin,
    this.onError,
    this.onStep,
    this.onLink,
    this.preview,
    this.loading,
  });

  /// The client to use. Defaults to the one of `Murkio.initialize`.
  final Murkio? murkio;

  final MurkioScreen screen;

  /// Language of the texts. Defaults to the option of `Murkio.initialize`,
  /// then the app's locale, then the device's.
  final String? locale;

  /// The user is signed in.
  final ValueChanged<MurkioSession>? onLogin;

  /// An action failed. The canvas already shows the translated message.
  final ValueChanged<MurkioException>? onError;

  /// A built-in screen opened (`verify_email`, `mfa`, `mfa_enroll`,
  /// `recovery_codes`, `forgot`, `reset`).
  final ValueChanged<String>? onStep;

  /// A link of the canvas was tapped. Without this callback an https link
  /// opens in the browser and a site path (`/terms`) does nothing: an app
  /// has no site to resolve it against.
  final ValueChanged<String>? onLink;

  /// A canvas document (the decoded JSON) to draw without the API: every
  /// element shows and the actions do nothing. For editors and tests.
  final Object? preview;

  /// What to show while the canvas loads. Defaults to nothing.
  final Widget? loading;

  @override
  State<MurkioIdentityCanvas> createState() => _MurkioIdentityCanvasState();
}

class _MurkioIdentityCanvasState extends State<MurkioIdentityCanvas> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final FocusNode _emailFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();
  final Map<String, GlobalKey> _keys = {};
  Murkio? _murkio;
  FlowController? _flow;
  CanvasDocument? _document;
  PublicConfig? _config;
  bool _failed = false;
  bool? _keepLogged;
  bool _obscure = true;
  MurkioException? _lastError;
  String _lastStep = 'sign_in';
  int _generation = 0;

  bool get _isPreview => widget.preview != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MurkioIdentityCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.preview, widget.preview) ||
        oldWidget.murkio != widget.murkio) {
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    _flow?.removeListener(_flowChanged);
    _flow?.dispose();
    _email.dispose();
    _password.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// Starts loading the canvas. The client is resolved here, not inside the
  /// asynchronous part, so a missing `Murkio.initialize` fails the build with
  /// its own message instead of an unhandled error later.
  void _load() {
    final generation = ++_generation;
    _flow?.removeListener(_flowChanged);
    _flow?.dispose();
    _flow = null;

    if (_isPreview) {
      final document = pickCanvas(widget.preview, null, onProblems: _warn);
      void apply() {
        _murkio = null;
        _config = null;
        _failed = false;
        _document = document;
      }

      // initState may not call setState; later reloads must.
      _document == null && _murkio == null ? apply() : setState(apply);
      return;
    }
    _fetch(widget.murkio ?? Murkio.instance, generation);
  }

  Future<void> _fetch(Murkio murkio, int generation) async {
    PublicConfig? config;
    CanvasDocument document;
    var failed = false;
    try {
      await murkio.start();
      final bootstrap = await murkio.bootstrap();
      config = bootstrap.config;
      document = pickCanvas(
        bootstrap.canvasDocument,
        config,
        onProblems: _warn,
      );
    } on MurkioException {
      failed = true;
      document = defaultCanvas();
    }
    if (!mounted || generation != _generation) return;

    final flow = FlowController(murkio)..addListener(_flowChanged);
    setState(() {
      _murkio = murkio;
      _flow = flow;
      _config = config;
      _document = document;
      _failed = failed;
      _lastStep = flow.state.step.name;
    });
  }

  void _warn(List<String> problems) {
    debugPrint(
      '[murkio] the canvas has problems; affected elements were '
      'skipped: ${problems.join('; ')}',
    );
  }

  void _flowChanged() {
    final flow = _flow;
    if (flow == null || !mounted) return;
    final state = flow.state;
    setState(() {});

    final error = state.error;
    if (error != null && !identical(error, _lastError)) {
      widget.onError?.call(error);
    }
    _lastError = error;

    final name = state.step.name;
    if (name != _lastStep) {
      _lastStep = name;
      if (state.inStep) widget.onStep?.call(name);
      if (state.step is DoneStep) {
        // Lets the password manager offer to save, then drops the password.
        TextInput.finishAutofillContext();
        _password.clear();
        final session = _murkio?.currentSession;
        if (session != null) widget.onLogin?.call(session);
      }
    }
  }

  String get _locale {
    final murkio = _murkio;
    return resolveLocale(
      context,
      widgetLocale: widget.locale,
      optionLocale: murkio?.localeOption,
      deviceLocale: WidgetsBinding.instance.platformDispatcher.locale
          .toLanguageTag(),
    );
  }

  bool _keepLoggedValue(CanvasScreen screen) {
    final chosen = _keepLogged;
    if (chosen != null) return chosen;
    for (final element in screen.elements) {
      if (element.type == CanvasElementType.keepLogged &&
          isVisible(element, _isPreview ? null : _config, oauth: true)) {
        return element.defaultChecked;
      }
    }
    // No checkbox on the screen: an app keeps its user signed in.
    return true;
  }

  void _act(String action, CanvasScreen screen, {String? provider}) {
    final flow = _flow;
    if (flow == null || _isPreview) return;
    final credentials = MurkioCredentials(
      email: _email.text,
      password: _password.text,
      keepLogged: _keepLoggedValue(screen),
    );
    switch (action) {
      case 'login':
        flow.login(credentials);
      case 'register':
        flow.register(credentials);
      case 'forgot':
        flow.forgot(_email.text);
      case 'oauth':
        flow.oauth(provider!, keepLogged: credentials.keepLogged);
    }
  }

  void _openLink(String href) {
    final onLink = widget.onLink;
    if (onLink != null) {
      onLink(href);
      return;
    }
    if (href.startsWith('/') || _isPreview) return;
    final url = Uri.tryParse(href);
    if (url != null) _murkio?.openUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    if (document == null) return widget.loading ?? const SizedBox.shrink();

    final flow = _flow;
    final state = flow?.state ?? const FlowState();
    final locale = _locale;
    final Widget child;
    if (flow != null && state.inStep) {
      child = MurkioStepView(
        flow: flow,
        theme: document.theme,
        locale: locale,
        onOpenUrl: (url) => _murkio?.openUrl(url),
      );
    } else {
      child = LayoutBuilder(
        builder: (context, constraints) =>
            _frame(context, constraints, document, state, locale),
      );
    }
    return MurkioEnvironment(child: child);
  }

  Widget _frame(
    BuildContext context,
    BoxConstraints constraints,
    CanvasDocument document,
    FlowState state,
    String locale,
  ) {
    final signUp =
        widget.screen == MurkioScreen.signUp && document.signUp != null;
    final screen = signUp ? document.signUp! : document.signIn;
    final config = _isPreview ? null : _config;
    final oauth = _isPreview || (_murkio?.oauthEnabled ?? false);
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : screen.desktop.width.toDouble();
    final placement = place(screen, width, config: config, oauth: oauth);
    final submit = submitAction(
      screen,
      signUp: signUp,
      config: config,
      oauth: oauth,
    );

    final error = state.error;
    final message = error != null
        ? translateError(error.code, locale)
        : state.notice != null
        ? murkioString(locale, state.notice!)
        : _failed
        ? translateError('unknown', locale)
        : null;
    final isNotice = error == null && state.notice != null;
    final slot = placement.order
        .where((element) => element.type == CanvasElementType.errorMessage)
        .firstOrNull;

    final shared = _ElementContext(
      theme: document.theme,
      base: themeTextStyle(document.theme, context),
      locale: locale,
      busy: state.busy,
      signUp: signUp,
      submit: submit,
      message: message,
      isNotice: isNotice,
      slotId: slot?.id,
    );

    final reading = {
      for (var i = 0; i < placement.order.length; i++) placement.order[i].id: i,
    };
    final children = <Widget>[];
    for (final element in placement.paint) {
      final rect = placement.rects[element.id]!;
      Widget child = KeyedSubtree(
        key: _keys.putIfAbsent(element.id, () => GlobalKey()),
        child: _element(element, screen, shared),
      );
      final order = reading[element.id]!.toDouble();
      child = Semantics(
        sortKey: OrdinalSortKey(order),
        child: FocusTraversalOrder(
          order: NumericFocusOrder(order),
          child: child,
        ),
      );
      if (element.type.decorative) child = IgnorePointer(child: child);
      children.add(
        Positioned(
          key: ValueKey('murkio-el-${element.id}'),
          left: rect.x,
          top: rect.y,
          width: rect.w,
          height: rect.h,
          child: child,
        ),
      );
    }

    Widget frame = SizedBox(
      key: const ValueKey('murkio-frame'),
      width: placement.frameWidth,
      height: placement.frameHeight,
      child: Stack(clipBehavior: Clip.none, children: children),
    );
    final background = placement.background;
    if (background != null) {
      frame = ColoredBox(color: Color(background), child: frame);
    }
    frame = MediaQuery.withClampedTextScaling(
      maxScaleFactor: _maxTextScale,
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: AutofillGroup(child: frame),
      ),
    );

    return Align(
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          frame,
          if (slot == null && message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: placement.frameWidth,
                child: _message(shared, shared.base, 14),
              ),
            ),
        ],
      ),
    );
  }

  Widget _message(
    _ElementContext c,
    TextStyle style,
    double fontSize, {
    Color? color,
    TextAlign align = TextAlign.start,
    FontWeight? weight,
  }) {
    return Semantics(
      liveRegion: true,
      child: Text(
        c.message ?? '',
        key: const ValueKey('murkio-message'),
        textAlign: align,
        style: style.copyWith(
          fontSize: fontSize,
          fontWeight: weight,
          color: c.isNotice
              ? Color(c.theme.text)
              : color ?? Color(c.theme.error),
        ),
      ),
    );
  }

  Widget _element(
    CanvasElement element,
    CanvasScreen screen,
    _ElementContext c,
  ) {
    final look = resolveLook(element, c.theme);
    final theme = c.theme;
    TextStyle textStyle() => c.base.copyWith(
      fontSize: look.fontSize,
      fontWeight: look.weight,
      color: look.foreground,
    );

    switch (element.type) {
      case CanvasElementType.emailInput:
        final label = element.label!.pick(c.locale);
        final placeholder = element.placeholder?.pick(c.locale) ?? '';
        return MurkioTextField(
          look: look,
          textStyle: c.base,
          label: label,
          hint: placeholder.isEmpty ? label : placeholder,
          hintColor: Color(theme.muted),
          accent: Color(theme.primary),
          controller: _email,
          focusNode: _emailFocus,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.username, AutofillHints.email],
          action: TextInputAction.next,
          onSubmitted: _passwordFocus.requestFocus,
        );

      case CanvasElementType.passwordInput:
        final label = element.label!.pick(c.locale);
        final placeholder = element.placeholder?.pick(c.locale) ?? '';
        return MurkioTextField(
          look: look,
          textStyle: c.base,
          label: label,
          hint: placeholder.isEmpty ? label : placeholder,
          hintColor: Color(theme.muted),
          accent: Color(theme.primary),
          controller: _password,
          focusNode: _passwordFocus,
          obscure: _obscure,
          autofillHints: [
            c.signUp ? AutofillHints.newPassword : AutofillHints.password,
          ],
          onSubmitted: () => _act(c.submit, screen),
          trailing: element.showToggle
              ? Semantics(
                  button: true,
                  toggled: !_obscure,
                  label: murkioString(
                    c.locale,
                    _obscure ? 'password.show' : 'password.hide',
                  ),
                  child: InkResponse(
                    key: const ValueKey('murkio-password-toggle'),
                    radius: 20,
                    onTap: () => setState(() => _obscure = !_obscure),
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: Center(
                        child: CustomPaint(
                          size: const Size(20, 20),
                          painter: EyePainter(
                            Color(theme.muted),
                            crossed: !_obscure,
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : null,
        );

      case CanvasElementType.keepLogged:
        final checked = _keepLoggedValue(screen);
        final primary = Color(theme.primary);
        return Semantics(
          checked: checked,
          label: element.label!.pick(c.locale),
          excludeSemantics: true,
          onTap: () => setState(() => _keepLogged = !checked),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _keepLogged = !checked),
            child: decorateBox(
              look,
              Row(
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: checked ? primary : null,
                      border: Border.all(
                        color: checked ? primary : Color(theme.border),
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: checked
                        ? CustomPaint(
                            painter: CheckPainter(Color(theme.onPrimary)),
                          )
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      element.label!.pick(c.locale),
                      textAlign: look.align,
                      style: textStyle(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

      case CanvasElementType.loginButton:
      case CanvasElementType.registerButton:
        final action = element.type == CanvasElementType.loginButton
            ? 'login'
            : 'register';
        return MurkioButton(
          label: element.label!.pick(c.locale),
          look: look,
          textStyle: c.base,
          busy: c.busy,
          onTap: () => _act(action, screen),
        );

      case CanvasElementType.oauthButton:
        final provider = element.provider!;
        final label = element.label?.pick(c.locale) ?? '';
        return MurkioButton(
          label: label.isEmpty
              ? murkioString(c.locale, 'oauth.continue', {
                  'provider': providerName(provider),
                })
              : label,
          look: look,
          textStyle: c.base,
          busy: c.busy,
          onTap: () => _act('oauth', screen, provider: provider),
        );

      case CanvasElementType.forgotPasswordLink:
        return MurkioButton(
          label: element.label!.pick(c.locale),
          look: look,
          textStyle: c.base,
          busy: c.busy,
          underline: true,
          onTap: () => _act('forgot', screen),
        );

      case CanvasElementType.link:
        return MurkioButton(
          label: element.text!.pick(c.locale),
          look: look,
          textStyle: c.base,
          underline: true,
          top: true,
          onTap: () => _openLink(element.href!),
        );

      case CanvasElementType.errorMessage:
        final shown = element.id == c.slotId && c.message != null;
        return decorateBox(
          look,
          _overflowing(
            look,
            shown
                ? _message(
                    c,
                    c.base,
                    look.fontSize,
                    color: look.foreground,
                    align: look.align,
                    weight: look.weight,
                  )
                : const SizedBox.shrink(),
          ),
        );

      case CanvasElementType.text:
        return decorateBox(
          look,
          _overflowing(
            look,
            Semantics(
              header: element.isHeading,
              child: Text(
                element.text!.pick(c.locale),
                textAlign: look.align,
                style: textStyle(),
              ),
            ),
          ),
        );

      case CanvasElementType.image:
        final alt = element.alt?.pick(c.locale) ?? '';
        return decorateBox(look, _image(element.src!, alt), clip: true);

      case CanvasElementType.shape:
        return ExcludeSemantics(
          child: decorateBox(look, const SizedBox.expand()),
        );

      case CanvasElementType.divider:
        final label = element.label?.pick(c.locale) ?? '';
        final line = Expanded(
          child: Container(height: 1, color: Color(theme.border)),
        );
        return decorateBox(
          look,
          Row(
            children: [
              line,
              if (label.isNotEmpty) ...[
                const SizedBox(width: 12),
                Text(label, style: textStyle()),
                const SizedBox(width: 12),
                line,
              ],
            ],
          ),
        );
    }
  }

  /// Text starts at the top of its box and, like on the web, is not cut when
  /// a font makes it a little taller than the box the editor drew.
  Widget _overflowing(ElementLook look, Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => OverflowBox(
        alignment: look.alignment(top: true),
        minWidth: constraints.maxWidth,
        maxWidth: constraints.maxWidth,
        minHeight: 0,
        maxHeight: double.infinity,
        child: child,
      ),
    );
  }

  Widget _image(String src, String alt) {
    Widget broken(BuildContext _, Object _, StackTrace? _) =>
        const SizedBox.shrink();
    final excluded = alt.isEmpty;
    if (src.startsWith('data:')) {
      final Uint8List bytes;
      try {
        bytes = base64.decode(src.substring(src.indexOf(',') + 1));
      } on FormatException {
        return const SizedBox.shrink();
      }
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        semanticLabel: excluded ? null : alt,
        excludeFromSemantics: excluded,
        errorBuilder: broken,
      );
    }
    return Image.network(
      src,
      fit: BoxFit.contain,
      semanticLabel: excluded ? null : alt,
      excludeFromSemantics: excluded,
      errorBuilder: broken,
    );
  }
}

/// What every element of one build needs to know.
class _ElementContext {
  const _ElementContext({
    required this.theme,
    required this.base,
    required this.locale,
    required this.busy,
    required this.signUp,
    required this.submit,
    required this.message,
    required this.isNotice,
    required this.slotId,
  });

  final CanvasTheme theme;
  final TextStyle base;
  final String locale;
  final bool busy;
  final bool signUp;
  final String submit;
  final String? message;
  final bool isNotice;
  final String? slotId;
}
