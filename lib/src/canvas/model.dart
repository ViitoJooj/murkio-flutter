import '../i18n.dart';

/// A canvas text: the default and its translations by locale.
class LocalizedText {
  const LocalizedText(this.fallback, [this.translations = const {}]);

  final String fallback;
  final Map<String, String> translations;

  /// The translation of the exact locale, then of its language, then the
  /// default text.
  String pick(String locale) {
    final normalized = normalizeLocale(locale);
    return translations[normalized] ??
        translations[languageOf(normalized)] ??
        fallback;
  }
}

/// The kinds of element a canvas can hold.
enum CanvasElementType {
  emailInput('email_input'),
  passwordInput('password_input'),
  keepLogged('keep_logged'),
  loginButton('login_button'),
  registerButton('register_button'),
  forgotPasswordLink('forgot_password_link'),
  oauthButton('oauth_button'),
  errorMessage('error_message'),
  text('text'),
  link('link'),
  image('image'),
  shape('shape'),
  divider('divider');

  const CanvasElementType(this.wire);

  /// The name in the canvas document.
  final String wire;

  static CanvasElementType? parse(Object? value) {
    for (final type in values) {
      if (type.wire == value) return type;
    }
    return null;
  }

  /// Decorative elements never take a touch and are painted under the
  /// interactive ones.
  bool get decorative =>
      this == text || this == image || this == shape || this == divider;

  /// The elements that only make sense with the password login.
  bool get needsPassword =>
      this == emailInput ||
      this == passwordInput ||
      this == keepLogged ||
      this == loginButton ||
      this == registerButton ||
      this == forgotPasswordLink;
}

/// Horizontal alignment of an element's text.
enum CanvasTextAlign { left, center, right }

/// The shadow presets of a canvas style.
enum CanvasShadow { none, sm, md, lg }

/// The allowed style of an element. Colors are 32-bit ARGB values; a null
/// field means "the default of the element".
class CanvasStyle {
  const CanvasStyle({
    this.color,
    this.background,
    this.borderColor,
    this.borderWidth,
    this.radius,
    this.fontSize,
    this.fontWeight,
    this.textAlign,
    this.padding,
    this.opacity,
    this.shadow,
  });

  final int? color;
  final int? background;
  final int? borderColor;
  final int? borderWidth;
  final int? radius;
  final int? fontSize;
  final int? fontWeight;
  final CanvasTextAlign? textAlign;
  final int? padding;
  final double? opacity;
  final CanvasShadow? shadow;
}

/// One element of a screen: what it is, its texts and its style.
class CanvasElement {
  const CanvasElement({
    required this.id,
    required this.type,
    this.style = const CanvasStyle(),
    this.label,
    this.placeholder,
    this.text,
    this.alt,
    this.showToggle = false,
    this.defaultChecked = false,
    this.provider,
    this.variant = '',
    this.href,
    this.src,
  });

  final String id;
  final CanvasElementType type;
  final CanvasStyle style;

  /// Inputs, buttons, links to "forgot password", the divider.
  final LocalizedText? label;

  /// Inputs.
  final LocalizedText? placeholder;

  /// `text` and `link`.
  final LocalizedText? text;

  /// `image`.
  final LocalizedText? alt;

  /// `password_input`: show the button that reveals the password.
  final bool showToggle;

  /// `keep_logged`: starts checked.
  final bool defaultChecked;

  /// `oauth_button`.
  final String? provider;

  /// `text`: `body` (or empty), `h1`, `h2`, `h3`.
  final String variant;

  /// `link`: an https URL or a site path.
  final String? href;

  /// `image`: an https URL or a `data:` image.
  final String? src;

  bool get isHeading => variant == 'h1' || variant == 'h2' || variant == 'h3';

  /// The same element with another style.
  CanvasElement withStyle(CanvasStyle style) => CanvasElement(
    id: id,
    type: type,
    style: style,
    label: label,
    placeholder: placeholder,
    text: text,
    alt: alt,
    showToggle: showToggle,
    defaultChecked: defaultChecked,
    provider: provider,
    variant: variant,
    href: href,
    src: src,
  );
}

/// Where an element sits in a layout.
class CanvasItem {
  const CanvasItem({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.z,
    this.hidden = false,
  });

  final int x;
  final int y;
  final int w;
  final int h;
  final int z;
  final bool hidden;
}

/// The frame of a screen at one size and where each element goes in it.
class CanvasLayout {
  const CanvasLayout({
    required this.width,
    required this.height,
    required this.items,
    this.background,
  });

  final int width;
  final int height;

  /// 32-bit ARGB, or null for a transparent frame.
  final int? background;
  final Map<String, CanvasItem> items;
}

/// A screen: its elements (the content) and its layouts (the positions).
class CanvasScreen {
  const CanvasScreen({
    required this.elements,
    required this.desktop,
    this.mobile,
  });

  final List<CanvasElement> elements;
  final CanvasLayout desktop;
  final CanvasLayout? mobile;
}

/// The font of a canvas.
enum CanvasFont { systemSans, systemSerif, systemMono, inherit }

/// The colors (32-bit ARGB), the font and the corner radius of a canvas.
class CanvasTheme {
  const CanvasTheme({
    required this.font,
    required this.radius,
    required this.primary,
    required this.onPrimary,
    required this.text,
    required this.muted,
    required this.background,
    required this.surface,
    required this.border,
    required this.error,
  });

  final CanvasFont font;
  final int radius;
  final int primary;
  final int onPrimary;
  final int text;
  final int muted;
  final int background;
  final int surface;
  final int border;
  final int error;
}

/// A validated canvas, ready to draw.
class CanvasDocument {
  const CanvasDocument({
    required this.theme,
    required this.signIn,
    this.signUp,
  });

  final CanvasTheme theme;
  final CanvasScreen signIn;

  /// Optional: without it the sign-up uses the sign-in screen.
  final CanvasScreen? signUp;
}
