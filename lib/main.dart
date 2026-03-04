import 'package:flutter/material.dart';
import 'core/services.dart';
import 'ui/screens.dart';

void main() async {
  // Inisialisasi binding root Flutter
  WidgetsFlutterBinding.ensureInitialized();
  
  // Inisialisasi Service Notifikasi Terlebih Dahulu (Termasuk meminta Permission)
  await NotificationService().initialize();
  
  // Inisialisasi Manager Latar Belakang ALTH
  await BackgroundManager.initializeService();

  // Menjalankan UI Utama
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ALTH: Aku Lupa Tandai Hadir',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue.shade900),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}
