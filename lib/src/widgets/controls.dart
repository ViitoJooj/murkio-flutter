import 'package:flutter/material.dart';

import 'look.dart';

/// A text field painted by the SDK: the box comes from [look], and the
/// Material field inside it is stripped of the app's input theme so the
/// canvas looks the same in every app.
class MurkioTextField extends StatelessWidget {
  const MurkioTextField({
    super.key,
    required this.look,
    required this.textStyle,
    required this.label,
    required this.hint,
    required this.hintColor,
    required this.accent,
    required this.controller,
    this.focusNode,
    this.obscure = false,
    this.keyboardType = TextInputType.text,
    this.autofillHints = const [],
    this.action = TextInputAction.done,
    this.onSubmitted,
    this.trailing,
  });

  final ElementLook look;
  final TextStyle textStyle;

  /// The accessible name of the field.
  final String label;
  final String hint;
  final Color hintColor;

  /// Cursor and selection color.
  final Color accent;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool obscure;
  final TextInputType keyboardType;
  final List<String> autofillHints;
  final TextInputAction action;
  final VoidCallback? onSubmitted;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = textStyle.copyWith(
      fontSize: look.fontSize,
      fontWeight: look.weight,
      color: look.foreground,
    );
    final field = Theme(
      data: Theme.of(context).copyWith(
        inputDecorationTheme: const InputDecorationTheme(),
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: accent,
          selectionColor: accent.withValues(alpha: 0.3),
          selectionHandleColor: accent,
        ),
      ),
      child: Semantics(
        label: label,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: obscure,
          keyboardType: keyboardType,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          autofillHints: autofillHints,
          textInputAction: action,
          onSubmitted: (_) => onSubmitted?.call(),
          style: style,
          textAlign: look.align,
          cursorColor: accent,
          decoration: InputDecoration.collapsed(
            hintText: hint,
            hintStyle: style.copyWith(
              color: hintColor,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ),
    );
    return decorateBox(
      look,
      Row(
        children: [
          Expanded(child: field),
          ?trailing,
        ],
      ),
    );
  }
}

/// A button painted by the SDK. A null [onTap] disables it; [busy] dims it
/// while a request runs. With [underline] it is drawn as a link.
class MurkioButton extends StatelessWidget {
  const MurkioButton({
    super.key,
    required this.label,
    required this.look,
    required this.textStyle,
    required this.onTap,
    this.busy = false,
    this.underline = false,
    this.top = false,
  });

  final String label;
  final ElementLook look;
  final TextStyle textStyle;
  final VoidCallback? onTap;
  final bool busy;
  final bool underline;

  /// Aligns the text to the top of the box instead of its middle.
  final bool top;

  @override
  Widget build(BuildContext context) {
    final hasBorder = look.borderWidth > 0 && look.borderColor != null;
    final radius = BorderRadius.circular(look.radius);
    Widget result = Material(
      color: look.background ?? Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: hasBorder
            ? BorderSide(color: look.borderColor!, width: look.borderWidth)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Padding(
          padding: look.padding,
          child: Align(
            alignment: look.alignment(top: top),
            child: Text(
              label,
              textAlign: look.align,
              style: textStyle.copyWith(
                fontSize: look.fontSize,
                fontWeight: look.weight,
                color: look.foreground,
                decoration: underline ? TextDecoration.underline : null,
                decorationColor: look.foreground,
              ),
            ),
          ),
        ),
      ),
    );
    if (look.shadows.isNotEmpty) {
      result = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: look.shadows,
        ),
        child: result,
      );
    }
    final opacity = look.opacity * (busy ? 0.6 : 1);
    if (opacity < 1) result = Opacity(opacity: opacity, child: result);
    return Semantics(
      button: !underline,
      link: underline,
      enabled: onTap != null && !busy,
      child: result,
    );
  }
}
