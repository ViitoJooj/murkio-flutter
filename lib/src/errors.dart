import 'generated/spec.g.dart';
import 'i18n.dart';

/// One problem reported by the API.
class MurkioErrorDetail {
  const MurkioErrorDetail({
    required this.code,
    required this.message,
    this.path,
  });

  final String code;
  final String message;
  final String? path;
}

/// Every failure the SDK reports. [code] is the stable API code (`rsb-00`,
/// `bss-01`...), `network` when the request never got an answer and `unknown`
/// for anything without a code. Show [localized] to users and use [code] in
/// your own logic: the API [message] is English only.
class MurkioException implements Exception {
  MurkioException(
    this.code,
    this.status, {
    this.details = const [],
    String? message,
  }) : message = message ?? (details.isEmpty ? code : details.first.message);

  /// Reads the error of an API answer.
  factory MurkioException.fromResponse(int status, Object? body) {
    final details = <MurkioErrorDetail>[];
    if (body is Map && body['details'] is List) {
      for (final Object? item in body['details'] as List) {
        if (item is Map && item['code'] is String) {
          details.add(
            MurkioErrorDetail(
              code: item['code'] as String,
              message: item['message'] is String
                  ? item['message'] as String
                  : '',
              path: item['path'] is String ? item['path'] as String : null,
            ),
          );
        }
      }
    }
    return MurkioException(
      details.isEmpty ? 'unknown' : details.first.code,
      status,
      details: details,
    );
  }

  /// Any error as a [MurkioException] (`unknown` when it is something else).
  factory MurkioException.from(Object error) => error is MurkioException
      ? error
      : MurkioException('unknown', 0, message: error.toString());

  final String code;
  final int status;
  final List<MurkioErrorDetail> details;
  final String message;

  bool isCode(String value) => code == value;

  /// The message to show the user, in [locale].
  String localized([String locale = 'en']) => translateError(code, locale);

  @override
  String toString() => 'MurkioException($code, $status): $message';
}

/// Translates an error code (or `oauth.<error>` from a social sign-in return)
/// for the user.
String translateError(String code, [String locale = 'en']) {
  final table = tableFor(specErrors, locale);
  return table[code] ?? table['unknown'] ?? specErrors['en']!['unknown']!;
}
