import 'package:flutter/widgets.dart';

import '../canvas/model.dart';

/// How an element is painted: its defaults with the canvas style on top.
class ElementLook {
  const ElementLook({
    required this.foreground,
    required this.fontSize,
    this.background,
    this.borderColor,
    this.borderWidth = 0,
    this.radius = 0,
    this.weight = FontWeight.w400,
    this.align = TextAlign.start,
    this.padding = EdgeInsets.zero,
    this.opacity = 1,
    this.shadows = const [],
  });

  final Color foreground;
  final double fontSize;
  final Color? background;
  final Color? borderColor;
  final double borderWidth;
  final double radius;
  final FontWeight weight;
  final TextAlign align;
  final EdgeInsets padding;
  final double opacity;
  final List<BoxShadow> shadows;

  /// Where a single line of text sits horizontally in its box.
  Alignment alignment({required bool top}) {
    final x = switch (align) {
      TextAlign.center => 0.0,
      TextAlign.right || TextAlign.end => 1.0,
      _ => -1.0,
    };
    return Alignment(x, top ? -1 : 0);
  }
}

const Map<CanvasShadow, List<BoxShadow>> _shadows = {
  CanvasShadow.none: [],
  CanvasShadow.sm: [
    BoxShadow(color: Color(0x14000000), offset: Offset(0, 1), blurRadius: 2),
  ],
  CanvasShadow.md: [
    BoxShadow(color: Color(0x1F000000), offset: Offset(0, 4), blurRadius: 12),
  ],
  CanvasShadow.lg: [
    BoxShadow(color: Color(0x2E000000), offset: Offset(0, 12), blurRadius: 32),
  ],
};

FontWeight _weight(int value) => FontWeight.values[(value ~/ 100) - 1];

/// The look of [element]: the defaults of its type (from the canvas theme)
/// with the element's own style applied on top.
ElementLook resolveLook(CanvasElement element, CanvasTheme theme) {
  final style = element.style;
  final type = element.type;

  var foreground = Color(theme.text);
  Color? background;
  Color? border;
  var borderWidth = 0.0;
  var radius = 0.0;
  var fontSize = 16.0;
  var weight = FontWeight.w400;
  var align = TextAlign.start;
  var padding = EdgeInsets.zero;

  switch (type) {
    case CanvasElementType.emailInput:
    case CanvasElementType.passwordInput:
      background = Color(theme.surface);
      border = Color(theme.border);
      borderWidth = 1;
      radius = theme.radius.toDouble();
      padding = const EdgeInsets.symmetric(horizontal: 12);
    case CanvasElementType.loginButton:
    case CanvasElementType.registerButton:
      foreground = Color(theme.onPrimary);
      background = Color(theme.primary);
      radius = theme.radius.toDouble();
      weight = FontWeight.w600;
      align = TextAlign.center;
      padding = const EdgeInsets.symmetric(horizontal: 16);
    case CanvasElementType.oauthButton:
      background = Color(theme.surface);
      border = Color(theme.border);
      borderWidth = 1;
      radius = theme.radius.toDouble();
      weight = FontWeight.w600;
      align = TextAlign.center;
      padding = const EdgeInsets.symmetric(horizontal: 16);
    case CanvasElementType.forgotPasswordLink:
    case CanvasElementType.link:
      foreground = Color(theme.primary);
      fontSize = 14;
    case CanvasElementType.keepLogged:
      fontSize = 14;
    case CanvasElementType.errorMessage:
      foreground = Color(theme.error);
      fontSize = 14;
    case CanvasElementType.divider:
      foreground = Color(theme.muted);
      fontSize = 14;
    case CanvasElementType.text:
      if (element.isHeading) weight = FontWeight.w700;
    case CanvasElementType.image:
    case CanvasElementType.shape:
      break;
  }

  if (style.color != null) foreground = Color(style.color!);
  if (style.background != null) background = Color(style.background!);
  if (style.borderColor != null || style.borderWidth != null) {
    // Only a color means a 1px border; only a width takes the color the
    // element already has (its default border, else its text color).
    borderWidth = (style.borderWidth ?? 1).toDouble();
    border = style.borderColor != null
        ? Color(style.borderColor!)
        : border ?? foreground;
  }
  if (style.radius != null) radius = style.radius!.toDouble();
  if (style.fontSize != null) fontSize = style.fontSize!.toDouble();
  if (style.fontWeight != null) weight = _weight(style.fontWeight!);
  if (style.textAlign != null) {
    align = switch (style.textAlign!) {
      CanvasTextAlign.left => TextAlign.left,
      CanvasTextAlign.center => TextAlign.center,
      CanvasTextAlign.right => TextAlign.right,
    };
  }
  if (style.padding != null) {
    padding = EdgeInsets.all(style.padding!.toDouble());
  }

  return ElementLook(
    foreground: foreground,
    fontSize: fontSize,
    background: background,
    borderColor: border,
    borderWidth: borderWidth,
    radius: radius,
    weight: weight,
    align: align,
    padding: padding,
    opacity: style.opacity ?? 1,
    shadows: _shadows[style.shadow] ?? const [],
  );
}

/// The font of a canvas theme. `system-sans` is the platform's own font;
/// `inherit` keeps the font the app already uses around the canvas.
TextStyle themeTextStyle(CanvasTheme theme, BuildContext context) {
  switch (theme.font) {
    case CanvasFont.inherit:
      final inherited = DefaultTextStyle.of(context).style;
      return TextStyle(
        fontFamily: inherited.fontFamily,
        fontFamilyFallback: inherited.fontFamilyFallback,
      );
    case CanvasFont.systemSerif:
      return const TextStyle(
        fontFamily: 'Georgia',
        fontFamilyFallback: ['Times New Roman', 'Noto Serif', 'serif'],
      );
    case CanvasFont.systemMono:
      return monoTextStyle;
    case CanvasFont.systemSans:
      return const TextStyle();
  }
}

/// The platform's monospaced font (setup keys and recovery codes).
const TextStyle monoTextStyle = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Roboto Mono', 'Courier New', 'monospace'],
);

/// Paints the box of an element (shadow, background, border, radius,
/// padding and opacity) around [child].
Widget decorateBox(ElementLook look, Widget child, {bool clip = false}) {
  final hasBorder = look.borderWidth > 0 && look.borderColor != null;
  Widget result = Container(
    clipBehavior: clip && look.radius > 0 ? Clip.antiAlias : Clip.none,
    decoration: BoxDecoration(
      color: look.background,
      border: hasBorder
          ? Border.all(color: look.borderColor!, width: look.borderWidth)
          : null,
      borderRadius: look.radius > 0 ? BorderRadius.circular(look.radius) : null,
      boxShadow: look.shadows.isEmpty ? null : look.shadows,
    ),
    padding: look.padding,
    child: child,
  );
  if (look.opacity < 1) result = Opacity(opacity: look.opacity, child: result);
  return result;
}

/// The check of the "keep me signed in" box, drawn so the SDK does not
/// depend on an icon font.
class CheckPainter extends CustomPainter {
  const CheckPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 0.22, size.height * 0.52)
      ..lineTo(size.width * 0.42, size.height * 0.72)
      ..lineTo(size.width * 0.78, size.height * 0.30);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.13
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(CheckPainter oldDelegate) => oldDelegate.color != color;
}

/// The eye of the "show password" button; [crossed] draws the "hide" state.
class EyePainter extends CustomPainter {
  const EyePainter(this.color, {required this.crossed});

  final Color color;
  final bool crossed;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.08
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final outline = Path()
      ..moveTo(w * 0.08, h * 0.5)
      ..quadraticBezierTo(w * 0.5, h * 0.02, w * 0.92, h * 0.5)
      ..quadraticBezierTo(w * 0.5, h * 0.98, w * 0.08, h * 0.5)
      ..close();
    canvas.drawPath(outline, stroke);
    canvas.drawCircle(Offset(w * 0.5, h * 0.5), w * 0.14, stroke);
    if (crossed) {
      canvas.drawLine(
        Offset(w * 0.18, h * 0.86),
        Offset(w * 0.82, h * 0.14),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(EyePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.crossed != crossed;
}
