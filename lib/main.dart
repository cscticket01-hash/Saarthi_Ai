import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'main_dashboard_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: "AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A",
      appId: "1:751405981184:web:f1240e05c084bac7b242e5",
      messagingSenderId: "751405981184",
      projectId: "saarthi-ai-df12b",
      authDomain: "saarthi-ai-df12b.firebaseapp.com",
      storageBucket: "saarthi-ai-df12b.firebasestorage.app",
    ),
  );

  runApp(const SaarthiApp());
}

class SaarthiApp extends StatelessWidget {
  const SaarthiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vidya Saarthi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B141A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F2C34),
          elevation: 1,
        ),
      ),
      home: const MainDashboardScreen(),
    );
  }
}
