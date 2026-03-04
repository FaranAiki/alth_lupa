import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:html/parser.dart' show parse;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

// ==========================================
// 1. CONSTANTS (Penyimpanan Konfigurasi Fix)
// ==========================================
class AppConstants {
  static const String domainAsli = "https://six.itb.ac.id";
  static const String userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
}

// ==========================================
// 2. STORAGE SERVICE (Single Responsibility: Sesi)
// ==========================================
class StorageService {
  static const String _keyCookie = 'cookie_six';
  static const String _keyNim = 'nim_six';

  Future<void> saveSession(String cookie, String nim) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCookie, cookie);
    if (nim.isNotEmpty) await prefs.setString(_keyNim, nim);
  }

  Future<Map<String, String>> getSession() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'cookie': prefs.getString(_keyCookie) ?? '',
      'nim': prefs.getString(_keyNim) ?? '',
    };
  }

  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }
}

// ==========================================
// 3. NOTIFICATION SERVICE (Single Responsibility: Alarm & Izin)
// ==========================================
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin plugin = FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const linuxInit = LinuxInitializationSettings(defaultActionName: 'Buka Notifikasi');
    const initSettings = InitializationSettings(android: androidInit, linux: linuxInit);
    
    await plugin.initialize(initSettings);

    if (Platform.isAndroid) {
      final androidImpl = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      // MINTA IZIN NOTIFIKASI PADA ANDROID 13+
      await androidImpl?.requestNotificationsPermission();
      
      const channel = AndroidNotificationChannel(
        'my_foreground', 
        'ALTH Foreground Service', 
        description: 'Notifikasi persisten untuk automasi absen.', 
        importance: Importance.low, 
      );
      await androidImpl?.createNotificationChannel(channel);
    }
  }

  Future<void> showAlarm(String title, String body) async {
    const androidDetails = AndroidNotificationDetails(
        'absen_channel_loud', 'SIX Absen Notifikasi Keras',
        channelDescription: 'Notifikasi untuk absen SIX ITB',
        importance: Importance.max,
        priority: Priority.high,
        ticker: 'ticker',
        playSound: true,
        enableVibration: true); 
    const linuxDetails = LinuxNotificationDetails();
    const details = NotificationDetails(android: androidDetails, linux: linuxDetails);
    
    await plugin.show(0, title, body, details);
  }
}

// ==========================================
// 4. API SERVICE (Single Responsibility: Scraping HTML & HTTP)
// ==========================================
class ApiService {
  // Menambahkan parameter ServiceInstance untuk logging ke background
  Future<Map<String, dynamic>> checkJadwal(String nim, String cookie, ServiceInstance? service) async {
    try {
      String jadwalUrl = "${AppConstants.domainAsli}/app/mahasiswa:$nim+2025-2/kelas/jadwal/mahasiswa";
      var httpClient = HttpClient();
      var request = await httpClient.getUrl(Uri.parse(jadwalUrl));
      request.followRedirects = false; 
      request.headers.add('Cookie', cookie);
      request.headers.add('User-Agent', AppConstants.userAgent);

      var response = await request.close();
      
      if (response.statusCode == 302 || response.statusCode == 301) {
        return {'status': 'expired', 'message': 'Sesi habis atau URL salah (Status ${response.statusCode}). Silakan relogin.'};
      } else if (response.statusCode != 200) {
        return {'status': 'error', 'message': 'HTTP Status ${response.statusCode}'};
      }

      var responseBody = await response.transform(utf8.decoder).join();
      var document = parse(responseBody);
      
      int tanggalHariIni = DateTime.now().day;
      var cellHariIni = document.querySelector('td.bg-info');
      
      if (cellHariIni == null) {
        var tds = document.querySelectorAll('td');
        for (var td in tds) {
          var dateDiv = td.children.where((e) => e.localName == 'div').firstOrNull;
          if (dateDiv != null && dateDiv.text.trim() == tanggalHariIni.toString()) {
            cellHariIni = td;
            break;
          }
        }
      }

      if (cellHariIni != null) {
        var matkulDivs = cellHariIni.querySelectorAll('div[title]');
        if (matkulDivs.isEmpty) {
           return {'status': 'idle', 'message': 'Tanggal $tanggalHariIni: Tidak ada jadwal kuliah hari ini.'};
        }

        // Tampilkan daftar matkul yang ditemukan
        List<String> listMatkul = [];
        for (var matkul in matkulDivs) {
          listMatkul.add(matkul.attributes['title'] ?? "Mata Kuliah Tidak Diketahui");
        }
        service?.invoke('log', {'message': 'Matkul hari ini: ${listMatkul.join(", ")}'});

        for (var matkul in matkulDivs) {
          String namaMatkul = matkul.attributes['title'] ?? "Mata Kuliah Tidak Diketahui";
          var linkElement = matkul.querySelector("a.linkpertemuan");
          
          if (linkElement != null) {
            var dataUrl = linkElement.attributes['data-url'];
            if (dataUrl != null) {
              if (dataUrl.startsWith('/')) dataUrl = AppConstants.domainAsli + dataUrl;
              
              service?.invoke('log', {'message': 'Akses pertemuan: $namaMatkul'});
              bool adaAbsen = await _cekPopupAbsen(httpClient, dataUrl, cookie);
              if (adaAbsen) {
                return {'status': 'found', 'url': dataUrl, 'matkul': namaMatkul};
              }
            }
          }
        }
        return {'status': 'idle', 'message': 'Aman. Belum ada tombol absen terbuka untuk saat ini.'};
      } else {
        return {'status': 'error', 'message': 'Tidak dapat menemukan kolom untuk tanggal $tanggalHariIni di kalender.'};
      }
    } catch (e) {
      return {'status': 'error', 'message': 'Terjadi kesalahan internal: $e'};
    }
  }

  Future<bool> _cekPopupAbsen(HttpClient client, String urlPertemuan, String cookie) async {
    try {
      var req = await client.getUrl(Uri.parse(urlPertemuan));
      req.followRedirects = false;
      req.headers.add('Cookie', cookie);
      req.headers.add('User-Agent', AppConstants.userAgent);
      
      var res = await req.close();
      var body = await res.transform(utf8.decoder).join();
      var docDetail = parse(body);
      String textContent = docDetail.body?.text ?? "";
      
      if (textContent.contains("Tandai Hadir")) return true;
    } catch (e) {
      return false;
    }
    return false;
  }
}

// ==========================================
// 5. BACKGROUND MANAGER (Single Responsibility: Lifecycle Latar Belakang)
// ==========================================
class BackgroundManager {
  static Future<void> initializeService() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      debugPrint("Background service tidak didukung di platform Desktop. Mode lokal siap digunakan.");
      return;
    }

    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStartBackground,
        autoStart: true, // UBAH MENJADI TRUE AGAR LANGSUNG JALAN
        isForegroundMode: true,
        notificationChannelId: 'my_foreground',
        initialNotificationTitle: 'ALTH',
        initialNotificationContent: 'Menyiapkan automasi ALTH...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true, // UBAH MENJADI TRUE
        onForeground: onStartBackground,
        onBackground: onIosBackground,
      ),
    );
  }
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStartBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await NotificationService().initialize();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) => service.setAsForegroundService());
    service.on('setAsBackground').listen((_) => service.setAsBackgroundService());
  }
  service.on('stopService').listen((_) => service.stopSelf());

  final storage = StorageService();
  final api = ApiService();
  final notif = NotificationService();

  while (true) {
    final session = await storage.getSession();
    final cookie = session['cookie']!;
    final nim = session['nim']!;

    if (!cookie.contains('khongguan=')) {
      service.invoke('log', {'message': 'Sesi kosong, menghentikan automasi latar belakang.'});
      service.stopSelf();
      break;
    }

    DateTime sekarang = DateTime.now();
    int jam = sekarang.hour;

    if (jam < 8 || jam >= 16) {
      service.invoke('log', {'message': '💤 Jam ${jam.toString().padLeft(2, '0')}:${sekarang.minute.toString().padLeft(2, '0')} di luar jadwal. Tidur 1 jam...'});
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(title: "ALTH", content: "Tidur 1 jam (Di luar jadwal kuliah)");
      }
      await Future.delayed(const Duration(hours: 1));
      continue;
    }

    // MEMPERBARUI NOTIFIKASI FOREGROUND SAAT MENGECEK
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(title: "ALTH - Automasi Berjalan", content: "Mengecek jadwal SIX ITB secara aktif...");
    }
    service.invoke('log', {'message': 'Memulai pembacaan kalender SIX ITB...'});

    // DECOUPLED LOGIC: Panggil API Service yang bebas UI
    final result = await api.checkJadwal(nim, cookie, service);

    if (result['status'] == 'expired') {
      service.invoke('log', {'message': '🚨 ${result['message']}'});
      service.invoke('forceLogout'); 
      service.stopSelf();
      break;
    } else if (result['status'] == 'found') {
      service.invoke('log', {'message': '🔥 Absen TERSEDIA untuk ${result['matkul']}! Membunyikan alarm...'});
      service.invoke('foundAbsen', {'url': result['url']}); 
      
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(title: "🔥 ABSEN TERSEDIA!", content: "Ketuk untuk presensi: ${result['matkul']}");
      }
      await notif.showAlarm('🔥 ABSEN SIX ITB!', 'Tandai Hadir: ${result['matkul']}');
    } else {
      service.invoke('log', {'message': result['message']});
    }

    int delayDetik = 5 + Random().nextInt(6);
    service.invoke('log', {'message': 'Menunggu $delayDetik detik ....'});
    await Future.delayed(Duration(seconds: delayDetik));
  }
}
