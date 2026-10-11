import 'dart:convert';

import '../generated/spec.g.dart';
import '../models.dart';
import 'model.dart';

// The server validates every canvas before it is stored, but the SDK checks
// it again before drawing it in the customer's app (defense in depth: a bug
// or a compromised dashboard must not become a fake link or an invisible
// overlay on every login screen). The rules mirror the server's structural
// ones (libs/spec/canvas); an element that breaks them is dropped, a style
// value out of range is ignored, and a document without what a login needs
// is refused so the caller falls back to the default canvas.

const List<String> _providers = ['google', 'github', 'apple', 'facebook', 'x'];
const List<String> _colorNames = [
  'primary',
  'on_primary',
  'text',
  'muted',
  'background',
  'surface',
  'border',
  'error',
];
const Map<String, CanvasFont> _fonts = {
  'system-sans': CanvasFont.systemSans,
  'system-serif': CanvasFont.systemSerif,
  'system-mono': CanvasFont.systemMono,
  'inherit': CanvasFont.inherit,
};
const List<String> _styleKeys = [
  'color',
  'background',
  'border_color',
  'border_width',
  'radius',
  'font_size',
  'font_weight',
  'text_align',
  'padding',
  'opacity',
  'shadow',
];
final RegExp _color = RegExp(
  r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$',
);
final RegExp _elementId = RegExp(r'^[a-z0-9_-]{1,32}$');
final RegExp _locale = RegExp(r'^[a-z]{2,3}(-[A-Z]{2})?$');
final RegExp _dataImage = RegExp(
  r'^data:image/(png|jpeg|gif);base64,[A-Za-z0-9+/]+={0,2}$',
);
final RegExp _spaceOrBackslash = RegExp(r'[\s\\]');
const int _maxElements = 150;
const int _maxDataImages = 4;
const int _maxDataImageChars = 87384; // ceil(64 KiB / 3) * 4

/// Parses a canvas color (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, alpha
/// last) into a 32-bit ARGB value. Null when it is not one.
int? parseColor(Object? value) {
  if (value is! String || !_color.hasMatch(value)) return null;
  var hex = value.substring(1);
  if (hex.length <= 4) {
    hex = hex.split('').map((char) => '$char$char').join();
  }
  if (hex.length == 6) hex = '${hex}ff';
  final rgb = int.parse(hex.substring(0, 6), radix: 16);
  final alpha = int.parse(hex.substring(6, 8), radix: 16);
  return (alpha << 24 | rgb) & 0xffffffff;
}

bool _isInt(Object? value, int low, int high) =>
    value is num &&
    value.isFinite &&
    value == value.roundToDouble() &&
    value >= low &&
    value <= high;

bool _cleanText(Object? value, int maxChars, bool multiline) {
  if (value is! String || value.trim().isEmpty) return false;
  var length = 0;
  for (final code in value.runes) {
    if (++length > maxChars) return false;
    if (code == 0x0a && multiline) continue;
    if (code < 0x20 ||
        (code >= 0x7f && code < 0xa0) ||
        (code >= 0x202a && code <= 0x202e) ||
        (code >= 0x2066 && code <= 0x2069)) {
      return false;
    }
  }
  return true;
}

LocalizedText? _text(
  Object? value, {
  int maxChars = 120,
  bool multiline = false,
}) {
  if (value is! Map || !_cleanText(value['default'], maxChars, multiline)) {
    return null;
  }
  final translations = <String, String>{};
  final i18n = value['i18n'];
  if (i18n != null) {
    if (i18n is! Map || i18n.length > 20) return null;
    for (final entry in i18n.entries) {
      final locale = entry.key;
      if (locale is! String ||
          !_locale.hasMatch(locale) ||
          !_cleanText(entry.value, maxChars, multiline)) {
        return null;
      }
      translations[locale] = entry.value as String;
    }
  }
  return LocalizedText(value['default'] as String, translations);
}

/// True for an absolute https URL without credentials.
bool isHttpsUrl(Object? value) {
  if (value is! String ||
      value.length > 2048 ||
      _spaceOrBackslash.hasMatch(value)) {
    return false;
  }
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

/// True for what a canvas link may point to: an https URL or a site path.
bool isSafeHref(Object? value) {
  if (value is! String) return false;
  if (value.startsWith('/')) {
    return value.length <= 2048 &&
        !value.startsWith('//') &&
        !_spaceOrBackslash.hasMatch(value);
  }
  return isHttpsUrl(value);
}

bool _isImageSource(Object? value) =>
    isHttpsUrl(value) ||
    (value is String &&
        value.length <= _maxDataImageChars + 32 &&
        _dataImage.hasMatch(value));

/// Builds the element from its props, or null when a prop breaks a rule.
/// Unknown props are simply not read.
CanvasElement? _element(
  String id,
  CanvasElementType type,
  Map<Object?, Object?> props,
) {
  const style = CanvasStyle();
  LocalizedText? optional(String key) =>
      props[key] == null ? null : _text(props[key]);
  bool invalidOptional(String key) =>
      props[key] != null && _text(props[key]) == null;

  switch (type) {
    case CanvasElementType.emailInput:
    case CanvasElementType.passwordInput:
      final label = _text(props['label']);
      if (label == null || invalidOptional('placeholder')) return null;
      return CanvasElement(
        id: id,
        type: type,
        style: style,
        label: label,
        placeholder: optional('placeholder'),
        showToggle:
            type == CanvasElementType.passwordInput &&
            props['show_toggle'] == true,
      );
    case CanvasElementType.keepLogged:
    case CanvasElementType.loginButton:
    case CanvasElementType.registerButton:
    case CanvasElementType.forgotPasswordLink:
      final label = _text(props['label']);
      if (label == null) return null;
      return CanvasElement(
        id: id,
        type: type,
        style: style,
        label: label,
        defaultChecked:
            type == CanvasElementType.keepLogged &&
            props['default_checked'] == true,
      );
    case CanvasElementType.oauthButton:
      final provider = props['provider'];
      if (provider is! String ||
          !_providers.contains(provider) ||
          invalidOptional('label')) {
        return null;
      }
      return CanvasElement(
        id: id,
        type: type,
        style: style,
        provider: provider,
        label: optional('label'),
      );
    case CanvasElementType.text:
      final text = _text(props['text'], maxChars: 500, multiline: true);
      final variant = props['variant'];
      if (text == null ||
          !(variant == null ||
              const ['', 'body', 'h1', 'h2', 'h3'].contains(variant))) {
        return null;
      }
      return CanvasElement(
        id: id,
        type: type,
        style: style,
        text: text,
        variant: variant is String ? variant : '',
      );
    case CanvasElementType.link:
      final text = _text(props['text']);
      if (text == null || !isSafeHref(props['href'])) return null;
      return CanvasElement(
        id: id,
        type: type,
        style: style,
        text: text,
        href: props['href'] as String,
      );
    case CanvasElementType.image:
      if (invalidOptional('alt') || !_isImageSource(props['src'])) return null;
      return CanvasElement(
        id: id,
        type: type,
        style: style,
        alt: optional('alt'),
        src: props['src'] as String,
      );
    case CanvasElementType.divider:
      if (invalidOptional('label')) return null;
      return CanvasElement(
        id: id,
        type: type,
        style: style,
        label: optional('label'),
      );
    case CanvasElementType.errorMessage:
    case CanvasElementType.shape:
      return CanvasElement(id: id, type: type, style: style);
  }
}

CanvasStyle _style(Object? style, List<String> problems, String path) {
  if (style is! Map) return const CanvasStyle();
  final color = parseColor(style['color']);
  final background = parseColor(style['background']);
  final borderColor = parseColor(style['border_color']);
  final borderWidth =
      _isInt(style['border_width'], 0, 8) ? _int(style['border_width']) : null;
  final radius = _isInt(style['radius'], 0, 999) ? _int(style['radius']) : null;
  final fontSize =
      _isInt(style['font_size'], 12, 72) ? _int(style['font_size']) : null;
  final fontWeight =
      _isInt(style['font_weight'], 100, 900) &&
              _int(style['font_weight']) % 100 == 0
          ? _int(style['font_weight'])
          : null;
  final textAlign = switch (style['text_align']) {
    'left' => CanvasTextAlign.left,
    'center' => CanvasTextAlign.center,
    'right' => CanvasTextAlign.right,
    _ => null,
  };
  final padding =
      _isInt(style['padding'], 0, 64) ? _int(style['padding']) : null;
  final rawOpacity = style['opacity'];
  final opacity =
      rawOpacity is num && rawOpacity >= 0 && rawOpacity <= 1
          ? rawOpacity.toDouble()
          : null;
  final shadow = switch (style['shadow']) {
    'none' => CanvasShadow.none,
    'sm' => CanvasShadow.sm,
    'md' => CanvasShadow.md,
    'lg' => CanvasShadow.lg,
    _ => null,
  };

  final read = <String, Object?>{
    'color': color,
    'background': background,
    'border_color': borderColor,
    'border_width': borderWidth,
    'radius': radius,
    'font_size': fontSize,
    'font_weight': fontWeight,
    'text_align': textAlign,
    'padding': padding,
    'opacity': opacity,
    'shadow': shadow,
  };
  for (final key in style.keys) {
    if (!_styleKeys.contains(key) || read[key] == null) {
      problems.add('$path.$key: ignored style');
    }
  }

  return CanvasStyle(
    color: color,
    background: background,
    borderColor: borderColor,
    borderWidth: borderWidth,
    radius: radius,
    fontSize: fontSize,
    fontWeight: fontWeight,
    textAlign: textAlign,
    padding: padding,
    opacity: opacity,
    shadow: shadow,
  );
}

int _int(Object? value) => (value as num).toInt();

class _Layout {
  _Layout(this.width, this.height, this.background, this.items);

  final int width;
  final int height;
  final int? background;
  final Map<String, CanvasItem> items;

  CanvasLayout build() => CanvasLayout(
    width: width,
    height: height,
    background: background,
    items: Map.unmodifiable(items),
  );
}

_Layout? _layout(Object? value, List<String> problems, String path) {
  if (value is! Map ||
      !_isInt(value['width'], 240, 1920) ||
      !_isInt(value['height'], 240, 2400) ||
      value['items'] is! Map) {
    problems.add('$path: invalid layout');
    return null;
  }
  final width = _int(value['width']);
  final height = _int(value['height']);
  final items = <String, CanvasItem>{};
  for (final entry in (value['items'] as Map).entries) {
    final id = entry.key;
    final item = entry.value;
    if (id is String &&
        item is Map &&
        _isInt(item['x'], 0, width) &&
        _isInt(item['y'], 0, height) &&
        _isInt(item['w'], 1, width) &&
        _isInt(item['h'], 1, height) &&
        _int(item['x']) + _int(item['w']) <= width &&
        _int(item['y']) + _int(item['h']) <= height &&
        _isInt(item['z'], 0, 1000)) {
      items[id] = CanvasItem(
        x: _int(item['x']),
        y: _int(item['y']),
        w: _int(item['w']),
        h: _int(item['h']),
        z: _int(item['z']),
        hidden: item['hidden'] == true,
      );
    } else {
      problems.add('$path.items.$id: invalid item');
    }
  }
  final background = value['background'];
  return _Layout(
    width,
    height,
    background is Map ? parseColor(background['color']) : null,
    items,
  );
}

class _Counter {
  int images = 0;
}

CanvasScreen? _screen(
  Object? value,
  List<String> problems,
  String path,
  _Counter counter,
) {
  if (value is! Map || value['elements'] is! List || value['layouts'] is! Map) {
    problems.add('$path: invalid screen');
    return null;
  }
  final layouts = value['layouts'] as Map;
  final desktop = _layout(
    layouts['desktop'],
    problems,
    '$path.layouts.desktop',
  );
  if (desktop == null) return null;
  final mobile =
      layouts['mobile'] == null
          ? null
          : _layout(layouts['mobile'], problems, '$path.layouts.mobile');
  final present = [desktop, if (mobile != null) mobile];

  final raw = value['elements'] as List;
  if (raw.length > _maxElements) {
    problems.add('$path.elements: more than $_maxElements elements');
  }

  final ids = <String>{};
  final elements = <CanvasElement>[];
  for (var index = 0; index < raw.length && index < _maxElements; index++) {
    final at = '$path.elements[$index]';
    final Object? entry = raw[index];
    final Object? id = entry is Map ? entry['id'] : null;
    if (entry is! Map ||
        id is! String ||
        !_elementId.hasMatch(id) ||
        ids.contains(id)) {
      problems.add('$at: invalid or duplicate id');
      continue;
    }
    ids.add(id);

    final type = CanvasElementType.parse(entry['type']);
    final Object? rawProps = entry['props'];
    final Map<Object?, Object?>? props =
        rawProps is Map
            ? rawProps
            : rawProps == null
            ? const {}
            : null;
    if (type == null || props == null) {
      problems.add('$at: invalid ${entry['type']}');
      continue;
    }
    final element = _element(id, type, props);
    if (element == null) {
      problems.add('$at: invalid ${entry['type']}');
      continue;
    }
    if (type == CanvasElementType.image &&
        element.src!.startsWith('data:') &&
        ++counter.images > _maxDataImages) {
      problems.add('$at: more than $_maxDataImages embedded images');
      continue;
    }
    if (present.any((layout) => !layout.items.containsKey(id))) {
      problems.add('$at: missing from a layout');
      continue;
    }
    elements.add(
      element.withStyle(_style(entry['style'], problems, '$at.style')),
    );
  }

  for (final layout in present) {
    for (final id in layout.items.keys.toList()) {
      if (!ids.contains(id)) {
        problems.add('$path: item $id has no element');
        layout.items.remove(id);
      }
    }
  }

  return CanvasScreen(
    elements: List.unmodifiable(elements),
    desktop: desktop.build(),
    mobile: mobile?.build(),
  );
}

/// The result of checking a canvas document.
class SanitizeResult {
  const SanitizeResult(this.document, this.problems);

  /// The cleaned canvas, or null when it cannot be drawn (wrong schema, no
  /// sign_in screen or desktop layout, a broken theme).
  final CanvasDocument? document;

  /// Everything that was wrong, for logging and tests.
  final List<String> problems;
}

/// Checks a canvas document (the decoded JSON) before it is drawn.
SanitizeResult sanitizeDocument(Object? value) {
  final problems = <String>[];
  if (value is! Map ||
      value['schema'] != 1 ||
      value['theme'] is! Map ||
      value['screens'] is! Map) {
    return const SanitizeResult(null, ['not a schema 1 canvas']);
  }

  final theme = value['theme'] as Map;
  final Object? rawColors = theme['colors'];
  final colors = <String, int>{};
  if (rawColors is Map) {
    for (final name in _colorNames) {
      final color = parseColor(rawColors[name]);
      if (color != null) colors[name] = color;
    }
  }
  final font = _fonts[theme['font']];
  if (font == null ||
      !_isInt(theme['radius'], 0, 32) ||
      colors.length != _colorNames.length) {
    return const SanitizeResult(null, ['invalid theme']);
  }

  final screens = value['screens'] as Map;
  for (final name in screens.keys) {
    if (name != 'sign_in' && name != 'sign_up') {
      problems.add('screens.$name: unknown screen');
    }
  }

  final counter = _Counter();
  final signIn = _screen(
    screens['sign_in'],
    problems,
    'screens.sign_in',
    counter,
  );
  if (signIn == null) return SanitizeResult(null, problems);
  final signUp =
      screens['sign_up'] == null
          ? null
          : _screen(screens['sign_up'], problems, 'screens.sign_up', counter);

  return SanitizeResult(
    CanvasDocument(
      theme: CanvasTheme(
        font: font,
        radius: _int(theme['radius']),
        primary: colors['primary']!,
        onPrimary: colors['on_primary']!,
        text: colors['text']!,
        muted: colors['muted']!,
        background: colors['background']!,
        surface: colors['surface']!,
        border: colors['border']!,
        error: colors['error']!,
      ),
      signIn: signIn,
      signUp: signUp,
    ),
    problems,
  );
}

/// True when the screen still has what a password login needs (email,
/// password and a submit action).
bool canSignIn(CanvasScreen screen) {
  final types = screen.elements.map((element) => element.type).toSet();
  return types.contains(CanvasElementType.emailInput) &&
      types.contains(CanvasElementType.passwordInput) &&
      (types.contains(CanvasElementType.loginButton) ||
          types.contains(CanvasElementType.registerButton));
}

/// True when the screen can sign a user in with what the application has
/// turned on.
bool isUsable(CanvasScreen screen, PublicConfig? config) {
  if (config != null && !config.passwordEnabled) {
    return screen.elements.any(
      (element) =>
          element.type == CanvasElementType.oauthButton &&
          config.oauthProviders.contains(element.provider),
    );
  }
  return canSignIn(screen);
}

CanvasDocument? _default;

/// The default canvas (libs/spec/canvas/default.json).
CanvasDocument defaultCanvas() =>
    _default ??= sanitizeDocument(jsonDecode(specDefaultCanvas)).document!;

/// The canvas to draw: the published one when it passes the SDK's own checks
/// and still has what the application's login needs, else the default one.
/// [onProblems] receives what was skipped.
CanvasDocument pickCanvas(
  Object? raw,
  PublicConfig? config, {
  void Function(List<String> problems)? onProblems,
}) {
  if (raw == null) return defaultCanvas();
  final result = sanitizeDocument(raw);
  if (result.problems.isNotEmpty) onProblems?.call(result.problems);
  final document = result.document;
  if (document != null && isUsable(document.signIn, config)) return document;
  return defaultCanvas();
}
