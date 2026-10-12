# murkio_identity

Murkio identity for Flutter. With **only the publishable key** your app gets:

- `MurkioIdentityCanvas`: the login screen designed in the Murkio dashboard, drawn with
  native widgets, running the whole sign-in (signup, email code, two-step verification,
  password reset, social sign-in);
- `MurkioIdentityEmailInput`, `MurkioIdentityPasswordInput`, `MurkioIdentityKeepLogged`,
  `MurkioIdentityLoginButton` and `MurkioIdentityRegisterButton`: the same sign-in with
  your own layout and style;
- the session: stored in the Keychain / Keystore, refreshed on its own, and an access
  token ready for your API.

## Install

```yaml
dependencies:
  murkio_identity:
    git:
      url: https://github.com/ViitoJooj/murkio-flutter.git
```

Needs Flutter 3.32 or newer (Dart 3.8). Android needs `minSdkVersion 24` (the default of
current Flutter). Nothing to set up on iOS.

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:murkio_identity/murkio_identity.dart';

Future<void> main() async {
  await Murkio.initialize(publishableKey: 'pk_...');
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: MurkioAuthBuilder(
        builder: (context, session) =>
            session == null ? const LoginPage() : const HomePage(),
      ),
    );
  }
}

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(child: MurkioIdentityCanvas()),
      ),
    );
  }
}
```

That is the whole integration: `MurkioAuthBuilder` swaps the pages when the user signs in
or out, and the canvas is whatever was published in the dashboard (the default one until
then). `Murkio.initialize` restores the session of the last run before `runApp`, so the
first frame already knows who is signed in.

## The canvas

```dart
MurkioIdentityCanvas(
  screen: MurkioScreen.signIn,      // or signUp
  locale: 'pt-BR',                  // default: the app's locale, then the device's
  onLogin: (session) {},            // the user is signed in
  onError: (error) {},              // error.code is the API code (rsb-00...)
  onStep: (step) {},                // verify_email, mfa, mfa_enroll, recovery_codes, forgot, reset
  onLink: (href) {},                // a link of the canvas was tapped
)
```

- It takes the width it is given and is as tall as its layout: put it in a scroll view.
- The layout follows the **width of its container**, exactly like the web SDK: the
  desktop layout down to 75% of its width, then the mobile layout, then a stacked column.
  Boxes scale with the frame; fonts keep the size chosen in the editor.
- The canvas is validated again on the device before it is drawn. A published canvas that
  can no longer sign anybody in (say, the password field was removed) gives way to the
  default one.
- It works in `MaterialApp`, `CupertinoApp` and plain `WidgetsApp`.
- `preview:` draws a canvas document without the API (editors, tests, screenshots).
- A link to a site path (`/terms`) has no site to open in an app: handle it in `onLink`.
  Without `onLink`, https links open in the browser.

The email code, two-step verification, authenticator setup, recovery codes and password
reset screens are built in and follow the canvas colors and font.

## Your own form

```dart
Column(
  children: [
    const MurkioIdentityEmailInput(
      decoration: InputDecoration(labelText: 'Email'),
    ),
    const MurkioIdentityPasswordInput(
      decoration: InputDecoration(labelText: 'Password'),
    ),
    const MurkioIdentityKeepLogged(label: Text('Keep me signed in')),
    const MurkioIdentityError(),
    MurkioIdentityLoginButton(
      onLogin: (session) {},
      child: const Text('Sign in'),
    ),
    const MurkioIdentityRegisterButton(child: Text('Create account')),
  ],
)
```

The inputs are regular Material `TextField`s (style them with `decoration` and `style`);
the buttons are a `FilledButton` and an `OutlinedButton`, or anything you draw:

```dart
MurkioIdentityLoginButton(
  builder: (context, onPressed, busy) => CupertinoButton.filled(
    onPressed: onPressed, // null while a request runs
    child: Text(busy ? 'Signing in…' : 'Sign in'),
  ),
)
```

The widgets of a screen share one form, so they can sit anywhere in your layout. The
built-in screens (email code, 2FA, …) open in a dialog painted with the canvas theme.
Wrap a group in `MurkioIdentityForm` only if you need two independent forms at once, or
want `onLogin` / `onError` in one place.

## The session

```dart
final murkio = Murkio.instance;

murkio.isSignedIn;                       // right now
murkio.session.addListener(() {});       // sign-ins, sign-outs and refreshes
final token = await murkio.getToken();   // a valid access token, or null
final user = await murkio.getUser();     // email, roles, 2FA (cached for a minute)
await murkio.signOut();

// Your API, with "Authorization: Bearer <access token>" on every request:
final client = MurkioHttpClient();
final response = await client.get(Uri.parse('https://api.example.com/orders'));
```

- The tokens live in the platform's secure storage (Keychain on iOS, preferences encrypted
  with a Keystore key on Android), one record per publishable key. On iOS the record stays on the
  device: it is not synced to iCloud nor restored on another phone.
- The access token is renewed 90 seconds before it expires while the app is in the
  foreground, when the app comes back to it, and by `getToken()` whenever needed. Calls
  that happen at the same time share one request: the refresh token rotates on every
  use, and presenting a used one ends the session.
- Offline, the session is kept and `getToken()` throws a `MurkioException` with the code
  `network`. Only the API saying the session is over signs the user out.
- **"Keep me signed in" unchecked** means the session ends with the app: the next start
  logs it out. A canvas (or form) **without** that checkbox keeps the session, which is
  what people expect from an app.
- Your backend verifies the access token with a Murkio server SDK; the app never has to.

Use one isolate for Murkio. A background isolate with its own client would refresh the
same token behind the app's back.

## Social sign-in

A provider sends the user back to an **https** link registered in the application's
redirect URLs. In an app that link must be an
[App Link](https://developer.android.com/training/app-links) (Android) /
[Universal Link](https://developer.apple.com/documentation/xcode/supporting-universal-links-in-your-app)
(iOS) that opens your app:

```dart
await Murkio.initialize(
  publishableKey: 'pk_...',
  oauthRedirectUrl: 'https://app.example.com/auth/callback',
);
```

and the route that receives the link gives it to the SDK:

```dart
// go_router
GoRoute(
  path: '/auth/callback',
  redirect: (context, state) async {
    await Murkio.instance.handleRedirect(state.uri);
    return '/';
  },
)
```

`handleRedirect` returns `false` for a link that is not the answer to a sign-in this app
started. Without `oauthRedirectUrl` the canvas hides the social buttons: a button with
nowhere to come back to is not shown.

## Errors and languages

Every failure is a `MurkioException`: `code` is the API code (`rsb-00`, `rag-06`…),
`network` when there was no answer, `unknown` otherwise. `error.localized('pt-BR')` is the
message for the user; the canvas and `MurkioIdentityError` already show it. English and
Brazilian Portuguese are built in; any other language falls back to English, and the texts
of the canvas itself come translated from the dashboard.

## Testing your app

```dart
final murkio = Murkio(
  publishableKey: 'pk_test',
  storage: MurkioMemoryStorage(),
  httpClient: MockClient((request) async => http.Response('{}', 200)),
  observeLifecycle: false,
);
await murkio.start();
await tester.pumpWidget(MaterialApp(home: MurkioIdentityCanvas(murkio: murkio)));
```

Every widget takes a `murkio:` so a test never needs the global instance.

## Developing

```sh
flutter pub get
flutter test
```

The tests run the vectors and fixtures every Murkio client SDK shares (the web SDK runs
the same ones), so the canvas is laid out and the flows behave like on the web. That copy
(`spec/`), `lib/src/generated/spec.g.dart` and the checks in `infra/pipeline/` are kept
in the Murkio identity service and synced from there, so they are not edited here.
Set `MURKIO_LIVE_API`, `MURKIO_LIVE_PK`, `MURKIO_LIVE_EMAIL` and `MURKIO_LIVE_PASSWORD` to
also run `test/live_test.dart` against a real API.

Every pull request runs the workflows in `.github/workflows`. The same checks, locally:

| Workflow | What it runs |
| --- | --- |
| Build | creates the Android project of `example/` and runs `flutter build apk --debug` |
| Format | `dart format --output=none --set-exit-if-changed .` |
| Lint | `flutter analyze --fatal-infos` (the package and the example) |
| Tests | `flutter test` on Flutter 3.32.0 (the oldest supported) and on the current release |
| Quality & Governance Checks | `for check in infra/pipeline/*.py; do python3 "$check"; done` |
| Security | `osv-scanner scan source --lockfile pubspec.lock`, `gitleaks git .`, `zizmor --pedantic .` |
| Dependency Review | run by GitHub on the pull request |

Security reports: see [SECURITY.md](SECURITY.md).
