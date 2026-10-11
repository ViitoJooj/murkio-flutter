import '../models.dart';
import 'model.dart';

/// The layout a canvas is drawn with.
enum CanvasLayoutName { desktop, mobile, stack }

/// Layouts only shrink, and never below this: under it the text would not
/// fit the boxes, so the mobile layout (or the stack) takes over.
const double minScale = 0.75;

const double stackPaddingX = 16;
const double stackPaddingY = 24;
const double stackGap = 12;

/// Picks the layout for the width the canvas really has (its container, not
/// the screen: it may sit in a dialog or a side panel).
CanvasLayoutName chooseLayout(CanvasScreen screen, double width) {
  if (width >= screen.desktop.width * minScale) return CanvasLayoutName.desktop;
  final mobile = screen.mobile;
  if (mobile != null && width >= mobile.width * minScale) {
    return CanvasLayoutName.mobile;
  }
  return CanvasLayoutName.stack;
}

/// The elements top to bottom, then left to right, by the desktop layout:
/// the order of focus, of the screen reader and of the stacked layout.
List<CanvasElement> readingOrder(CanvasScreen screen) {
  final items = screen.desktop.items;
  final indexed = [
    for (var i = 0; i < screen.elements.length; i++) (i, screen.elements[i]),
  ];
  indexed.sort((a, b) {
    final ia = items[a.$2.id]!;
    final ib = items[b.$2.id]!;
    if (ia.y != ib.y) return ia.y.compareTo(ib.y);
    if (ia.x != ib.x) return ia.x.compareTo(ib.x);
    return a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}

/// Whether the application's config shows the element. A null [config]
/// shows everything (preview). [oauth] is false when the app has no return
/// link for the social sign-in: a button that cannot come back is hidden.
bool isVisible(
  CanvasElement element,
  PublicConfig? config, {
  required bool oauth,
}) {
  if (element.type == CanvasElementType.oauthButton && !oauth) return false;
  if (config == null) return true;
  if (!config.passwordEnabled && element.type.needsPassword) return false;
  if (element.type == CanvasElementType.oauthButton) {
    return config.oauthProviders.contains(element.provider);
  }
  return true;
}

/// What "submit" does (the keyboard's action button): `login` on the sign-in
/// screen with a visible login button, else `register`.
String submitAction(
  CanvasScreen screen, {
  required bool signUp,
  PublicConfig? config,
  required bool oauth,
}) {
  final hasLogin = screen.elements.any(
    (element) =>
        element.type == CanvasElementType.loginButton &&
        isVisible(element, config, oauth: oauth),
  );
  return hasLogin && !signUp ? 'login' : 'register';
}

/// A box in the frame, in logical pixels from its top left corner.
class CanvasRect {
  const CanvasRect(this.x, this.y, this.w, this.h);

  final double x;
  final double y;
  final double w;
  final double h;
}

/// Where everything goes for one container width.
class CanvasPlacement {
  const CanvasPlacement({
    required this.layout,
    required this.frameWidth,
    required this.frameHeight,
    required this.background,
    required this.order,
    required this.paint,
    required this.rects,
  });

  final CanvasLayoutName layout;
  final double frameWidth;
  final double frameHeight;

  /// 32-bit ARGB, or null for a transparent frame.
  final int? background;

  /// The drawn elements in reading order.
  final List<CanvasElement> order;

  /// The drawn elements bottom to top.
  final List<CanvasElement> paint;
  final Map<String, CanvasRect> rects;
}

/// Lays a screen out for a container [width].
CanvasPlacement place(
  CanvasScreen screen,
  double width, {
  PublicConfig? config,
  required bool oauth,
}) {
  final name = chooseLayout(screen, width);
  final layout =
      name == CanvasLayoutName.mobile ? screen.mobile! : screen.desktop;
  final frameWidth = width < layout.width ? width : layout.width.toDouble();
  final shown = [
    for (final element in readingOrder(screen))
      if (isVisible(element, config, oauth: oauth) &&
          !layout.items[element.id]!.hidden)
        element,
  ];
  final rects = <String, CanvasRect>{};

  if (name == CanvasLayoutName.stack) {
    var y = stackPaddingY;
    for (final element in shown) {
      final height = layout.items[element.id]!.h.toDouble();
      rects[element.id] = CanvasRect(
        stackPaddingX,
        y,
        frameWidth - 2 * stackPaddingX,
        height,
      );
      y += height + stackGap;
    }
    return CanvasPlacement(
      layout: name,
      frameWidth: frameWidth,
      frameHeight:
          shown.isEmpty ? 2 * stackPaddingY : y - stackGap + stackPaddingY,
      background: layout.background,
      order: shown,
      paint: shown,
      rects: rects,
    );
  }

  final scale = frameWidth / layout.width;
  for (final element in shown) {
    final item = layout.items[element.id]!;
    rects[element.id] = CanvasRect(
      item.x * scale,
      item.y * scale,
      item.w * scale,
      item.h * scale,
    );
  }
  int depth(CanvasElement element) =>
      (element.type.decorative ? 0 : 2000) + layout.items[element.id]!.z;
  final paint = [for (var i = 0; i < shown.length; i++) (i, shown[i])]
    ..sort((a, b) {
      final byDepth = depth(a.$2).compareTo(depth(b.$2));
      return byDepth != 0 ? byDepth : a.$1.compareTo(b.$1);
    });

  return CanvasPlacement(
    layout: name,
    frameWidth: frameWidth,
    frameHeight: layout.height * scale,
    background: layout.background,
    order: shown,
    paint: [for (final entry in paint) entry.$2],
    rects: rects,
  );
}
