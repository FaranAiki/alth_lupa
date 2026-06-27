import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'core/services.dart';
import 'ui/screens.dart';

void main() async {
  // Inisialisasi binding root Flutter
  // Ini buat memastikan root sudah diinitialize baru jalan
  WidgetsFlutterBinding.ensureInitialized();
  
  // Inisialisasi service notif 
  // Ini juga buat permission di Android
  await NotificationService().initialize();
  
  // Inisialisasi Manager Latar Belakang ALTH
  await BackgroundManager.initializeService();

  // Jalan ^^
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alth: Aku Lupa Tandai Hadir',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue.shade900),
        useMaterial3: true,
        textTheme: GoogleFonts.interTextTheme(),
      ),
      home: const SplashScreen(),
    );
  }
}
