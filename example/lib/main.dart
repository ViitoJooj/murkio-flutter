import 'package:flutter/material.dart';
import 'package:murkio_identity/murkio_identity.dart';

// flutter run --dart-define=MURKIO_PUBLISHABLE_KEY=pk_...
const publishableKey = String.fromEnvironment('MURKIO_PUBLISHABLE_KEY');
const apiUrl = String.fromEnvironment('MURKIO_API_URL');

Future<void> main() async {
  await Murkio.initialize(
    publishableKey: publishableKey,
    apiUrl: apiUrl.isEmpty ? null : apiUrl,
  );
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Murkio identity',
      home: MurkioAuthBuilder(
        builder:
            (context, session) =>
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

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Signed in'),
        actions: [
          IconButton(
            onPressed: Murkio.instance.signOut,
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: Center(
        child: FutureBuilder<MurkioUser?>(
          future: Murkio.instance.getUser(),
          builder: (context, snapshot) {
            final user = snapshot.data;
            if (user == null) return const CircularProgressIndicator();
            return Text(
              '${user.email ?? user.id}\n${user.roles.join(', ')}',
              textAlign: TextAlign.center,
            );
          },
        ),
      ),
    );
  }
}
