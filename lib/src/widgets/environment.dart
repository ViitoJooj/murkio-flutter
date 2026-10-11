import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// The SDK's screens use Material text fields, which need a Material ancestor
/// and Material localizations. Apps built on CupertinoApp or WidgetsApp have
/// neither, so the screens bring the defaults along instead of asking the
/// app to change.
class MurkioEnvironment extends StatelessWidget {
  const MurkioEnvironment({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget result = Material(type: MaterialType.transparency, child: child);
    final hasMaterial =
        Localizations.of<MaterialLocalizations>(
          context,
          MaterialLocalizations,
        ) !=
        null;
    if (!hasMaterial) {
      result = Localizations(
        locale: Localizations.maybeLocaleOf(context) ?? const Locale('en'),
        delegates: const [
          DefaultMaterialLocalizations.delegate,
          DefaultCupertinoLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        child: result,
      );
    }
    return result;
  }
}

/// The locale a widget speaks: its own parameter, the option given to
/// `Murkio.initialize`, the app's locale, then the device's.
String resolveLocale(
  BuildContext context, {
  String? widgetLocale,
  String? optionLocale,
  required String deviceLocale,
}) {
  return (widgetLocale ??
          optionLocale ??
          Localizations.maybeLocaleOf(context)?.toLanguageTag() ??
          deviceLocale)
      .replaceAll('_', '-');
}
