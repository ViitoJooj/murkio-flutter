import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:murkio_identity/src/canvas/validate.dart';

import 'support.dart';

List<File> fixtures(String kind) =>
    Directory('${specDir.path}/canvas/fixtures/$kind')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

Object? documentOf(File file) =>
    (jsonDecode(file.readAsStringSync()) as Map)['document'];

String nameOf(File file) => file.uri.pathSegments.last;

// The SDK skips what the server would reject but cannot hurt the app (an
// unknown field or prop): it never reads them, so the document still draws.
const ignoredByTheSdk = {'unknown-field.json', 'unknown-prop.json'};

void main() {
  group('sanitizeDocument against the shared fixtures', () {
    test('accepts the default canvas unchanged', () {
      final result = sanitizeDocument(readSpec('canvas/default.json'));
      expect(result.problems, isEmpty);
      expect(canSignIn(result.document!.signIn), isTrue);
      expect(result.document!.signIn.elements, hasLength(9));
      expect(
        defaultCanvas().signIn.elements.map((e) => e.id),
        result.document!.signIn.elements.map((e) => e.id),
      );
    });

    for (final kind in ['valid', 'unpublishable']) {
      for (final file in fixtures(kind)) {
        test('$kind/${nameOf(file)} has no structural problem', () {
          final result = sanitizeDocument(documentOf(file));
          expect(result.problems, isEmpty);
          expect(result.document, isNotNull);
        });
      }
    }

    for (final file in fixtures('invalid')) {
      test('invalid/${nameOf(file)} is caught', () {
        final result = sanitizeDocument(documentOf(file));
        if (ignoredByTheSdk.contains(nameOf(file))) {
          expect(result.document, isNotNull);
          return;
        }
        expect(result.document == null || result.problems.isNotEmpty, isTrue);
      });
    }

    test('there are fixtures to run', () {
      expect(fixtures('valid'), isNotEmpty);
      expect(fixtures('invalid').length, greaterThan(10));
    });
  });

  group('rules the fixtures do not spell out', () {
    Map<String, dynamic> base() =>
        jsonDecode(jsonEncode(readSpec('canvas/default.json')))
            as Map<String, dynamic>;
    List<dynamic> elements(Map<String, dynamic> doc) =>
        ((doc['screens'] as Map)['sign_in'] as Map)['elements'] as List;

    test('links only go to https or a site path', () {
      expect(isSafeHref('https://example.com/terms'), isTrue);
      expect(isSafeHref('/terms'), isTrue);
      expect(isSafeHref('//evil.example'), isFalse);
      expect(isSafeHref(r'/\evil.example'), isFalse);
      expect(isSafeHref('javascript:alert(1)'), isFalse);
      expect(isSafeHref('http://example.com'), isFalse);
      expect(isSafeHref('https://user:pw@example.com'), isFalse);
      expect(isSafeHref('https://exa mple.com'), isFalse);
      expect(isSafeHref('myapp://callback'), isFalse);
      expect(isSafeHref(42), isFalse);
    });

    test('a text with bidi or control characters drops its element', () {
      for (final bad in [
        'Sign${String.fromCharCode(0x202E)}in',
        'a${String.fromCharCode(7)}b',
        'x${String.fromCharCode(0x2066)}y',
        '   ',
      ]) {
        final doc = base();
        ((elements(doc)[0] as Map)['props'] as Map)['text'] = {'default': bad};
        final result = sanitizeDocument(doc);
        expect(
          result.document!.signIn.elements.any((e) => e.id == 'title'),
          isFalse,
          reason: bad.runes.toList().toString(),
        );
        expect(result.problems, isNotEmpty);
      }
    });

    test('only the text element keeps line breaks', () {
      final doc = base();
      ((elements(doc)[0] as Map)['props'] as Map)['text'] = {
        'default': 'two\nlines',
      };
      expect(sanitizeDocument(doc).problems, isEmpty);

      final other = base();
      ((elements(other)[6] as Map)['props'] as Map)['label'] = {
        'default': 'two\nlines',
      };
      expect(sanitizeDocument(other).problems, isNotEmpty);
    });

    test('a style out of range is ignored, the element stays', () {
      final doc = base();
      (elements(doc)[6] as Map)['style'] = {
        'font_size': 500,
        'opacity': 3,
        'color': 'url(javascript:1)',
        'radius': 12,
        'position': 'fixed',
      };
      final result = sanitizeDocument(doc);
      final login = result.document!.signIn.elements.firstWhere(
        (e) => e.id == 'login',
      );
      expect(login.style.fontSize, isNull);
      expect(login.style.opacity, isNull);
      expect(login.style.color, isNull);
      expect(login.style.radius, 12);
      expect(result.problems, hasLength(4));
    });

    test('numbers written as 8.0 count as integers, 8.5 does not', () {
      final doc = base();
      (elements(doc)[6] as Map)['style'] = {'radius': 8.0, 'padding': 8.5};
      final result = sanitizeDocument(doc);
      final login = result.document!.signIn.elements.firstWhere(
        (e) => e.id == 'login',
      );
      expect(login.style.radius, 8);
      expect(login.style.padding, isNull);
    });

    test('a document that is not a schema 1 canvas is refused', () {
      for (final Object? bad in [
        null,
        'x',
        3,
        <Object?>[],
        <String, Object?>{},
        {'schema': 2},
      ]) {
        expect(sanitizeDocument(bad).document, isNull);
      }
    });
  });
}
