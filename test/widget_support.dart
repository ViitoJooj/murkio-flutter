import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:murkio_identity/murkio_identity.dart';

import 'support.dart';

/// A widget test that leaves nothing behind: the tree is taken down and every
/// client is disposed inside the test, so no refresh timer outlives it.
void testMurkio(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2600);
    addTearDown(tester.view.reset);
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final murkio in liveClients.toList()) {
        murkio.dispose();
      }
      liveClients.clear();
      Murkio.reset();
    }
  });
}

/// Lets requests answer and animations end.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Pumps [child] at the top left of an app, in a box [width] wide, and waits
/// for it to load.
Future<void> pumpApp(
  WidgetTester tester,
  Widget child, {
  double width = 400,
  String host = 'material',
  Locale? appLocale,
  double textScale = 1,
}) async {
  final body = MediaQuery(
    data: MediaQueryData(
      size: const Size(1200, 2600),
      textScaler: TextScaler.linear(textScale),
    ),
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: child),
    ),
  );
  const delegates = [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];
  final Widget app;
  switch (host) {
    case 'cupertino':
      app = CupertinoApp(home: CupertinoPageScaffold(child: body));
    case 'widgets':
      app = WidgetsApp(
        color: const Color(0xFF000000),
        pageRouteBuilder:
            <T>(RouteSettings settings, WidgetBuilder builder) =>
                PageRouteBuilder<T>(
                  pageBuilder: (context, _, _) => builder(context),
                ),
        home: body,
      );
    default:
      app = MaterialApp(
        locale: appLocale,
        supportedLocales: const [Locale('en'), Locale('pt', 'BR')],
        localizationsDelegates: delegates,
        home: Scaffold(body: body),
      );
  }
  await tester.pumpWidget(app);
  await settle(tester);
}

/// The ids of the drawn elements, in the order the stack paints them.
List<String> elementIds(WidgetTester tester) {
  final stack = tester.widget<Stack>(
    find
        .descendant(
          of: find.byKey(const ValueKey('murkio-frame')),
          matching: find.byType(Stack),
        )
        .first,
  );
  return [
    for (final child in stack.children)
      (child.key! as ValueKey<String>).value.substring('murkio-el-'.length),
  ];
}

Finder fieldOf(String id) => find.descendant(
  of: find.byKey(ValueKey('murkio-el-$id')),
  matching: find.byType(TextField),
);

Future<void> tapElement(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('murkio-el-$id')));
  await settle(tester);
}

/// A fake API that serves the bootstrap plus [routes].
FakeApi canvasApi({
  Map<String, Handler> routes = const {},
  Object? document,
  bool password = true,
  List<String> providers = const [],
}) {
  return FakeApi({
    'GET /v1/client':
        (_) => Answer.data(
          bootstrapJson(
            document: document,
            password: password,
            providers: providers,
          ),
        ),
    ...routes,
  });
}

Map<String, dynamic> cloneDefault() =>
    jsonDecode(jsonEncode(readSpec('canvas/default.json')))
        as Map<String, dynamic>;

Map<String, dynamic> _signIn(Map<String, dynamic> document) =>
    (document['screens'] as Map<String, dynamic>)['sign_in']
        as Map<String, dynamic>;

void removeElement(Map<String, dynamic> document, String id) {
  final screen = _signIn(document);
  (screen['elements'] as List).removeWhere((e) => (e as Map)['id'] == id);
  for (final layout in (screen['layouts'] as Map).values) {
    ((layout as Map)['items'] as Map).remove(id);
  }
}

void addElement(
  Map<String, dynamic> document,
  Map<String, Object?> element,
  Map<String, Object?> item,
) {
  final screen = _signIn(document);
  (screen['elements'] as List).add(element);
  for (final layout in (screen['layouts'] as Map).values) {
    ((layout as Map)['items'] as Map)[element['id']] = item;
  }
}
