import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'developer_portal.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: 'AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A',
      appId: '1:751405981184:web:f1240e05c084bac7b242e5',
      messagingSenderId: '751405981184',
      projectId: 'saarthi-ai-df12b',
      authDomain: 'vidyasaarthi.web.app',
      storageBucket: 'saarthi-ai-df12b.firebasestorage.app',
    ),
  );

  runApp(const VidyaSaarthiApp());
}

class VidyaSaarthiApp extends StatelessWidget {
  const VidyaSaarthiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vidya Saarthi • Developer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(primary: Color(0xFF63E6BE), surface: Color(0xFF16242E)),
        inputDecorationTheme: const InputDecorationTheme(filled: true, fillColor: Color(0xFF16242E), border: OutlineInputBorder()),
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

