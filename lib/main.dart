import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'developer_portal.dart';
import 'platform/platform_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: platformApiKey,
      appId: developerStaging
          ? '1:163817346882:web:daf759154baf3f44b29adb'
          : '1:751405981184:web:f1240e05c084bac7b242e5',
      messagingSenderId: developerStaging ? '163817346882' : '751405981184',
      projectId: platformProjectId,
      authDomain: developerStaging
          ? 'saarthi-ai-staging.firebaseapp.com'
          : 'vidyasaarthi.web.app',
      storageBucket: '$platformProjectId.firebasestorage.app',
    ),
  );

  runApp(const VidyaSaarthiApp());
}

class VidyaSaarthiApp extends StatelessWidget {
  const VidyaSaarthiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: developerStaging
          ? 'Vidya Saarthi • Staging'
          : 'Vidya Saarthi • Developer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF63E6BE),
          surface: Color(0xFF16242E),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFF16242E),
          border: OutlineInputBorder(),
        ),
        scaffoldBackgroundColor: const Color(0xFF0B141A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F2C34),
          elevation: 1,
        ),
      ),
      home: const DeveloperPortal(),
    );
  }
}
