import 'generated/spec.g.dart';

/// `pt_BR` and `pt-BR` are the same locale; the tables use the hyphen.
String normalizeLocale(String locale) => locale.replaceAll('_', '-');

/// The language of a locale, without the region (`pt-BR` is `pt`).
String languageOf(String locale) => normalizeLocale(locale).split('-').first;

/// The table of a locale: the exact one, the Brazilian one for any
/// Portuguese, English for everything else.
Map<String, String> tableFor(
  Map<String, Map<String, String>> tables,
  String locale,
) {
  final normalized = normalizeLocale(locale);
  return tables[normalized] ??
      (languageOf(normalized) == 'pt' ? tables['pt-BR']! : tables['en']!);
}

final RegExp _placeholder = RegExp(r'\{(\w+)\}');

/// A text of the built-in screens (email code, two-step verification,
/// password reset), in the given locale.
String murkioString(
  String locale,
  String key, [
  Map<String, String> params = const {},
]) {
  final template =
      tableFor(specStrings, locale)[key] ?? specStrings['en']![key] ?? key;
  return template.replaceAllMapped(
    _placeholder,
    (match) => params[match.group(1)] ?? '',
  );
}

const Map<String, String> _providerNames = {
  'google': 'Google',
  'github': 'GitHub',
  'apple': 'Apple',
  'facebook': 'Facebook',
  'x': 'X',
};

/// The display name of a social sign-in provider.
String providerName(String provider) => _providerNames[provider] ?? provider;
