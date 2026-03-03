import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:html/parser.dart' show parse;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

// ==========================================
// INISIALISASI BACKGROUND SERVICE
// ==========================================
Future<void> initializeService() async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    debugPrint("Background service tidak didukung di platform ini. Mode lokal akan digunakan.");
    return;
  }

  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'my_foreground', 
    'ALTH Foreground Service', 
    description: 'Notifikasi persisten untuk automasi absen.', 
    importance: Importance.low, 
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false, // Akan dipanggil manual saat di Dashboard
      isForegroundMode: true,
      notificationChannelId: 'my_foreground',
      initialNotificationTitle: 'ALTH',
      initialNotificationContent: 'Aku Lupa Tandai Hadir sedang berjalan.',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

// ==========================================
// LOGIKA UTAMA BACKGROUND
// ==========================================
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  const String domainAsli = "https://six.itb.ac.id";
  
  while (true) {
    final prefs = await SharedPreferences.getInstance();
    final cookie = prefs.getString('cookie_six') ?? "";
    final nim = prefs.getString('nim_six') ?? "";

    // Pengecekan login via khongguan (nissin otomatis ditambahkan saat login)
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

    service.invoke('log', {'message': 'Memulai pengecekan jadwal SIX ITB...'});
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(title: "ALTH", content: "Aku Lupa Tandai Hadir sedang berjalan.");
    }

    try {
      String jadwalUrl = "$domainAsli/app/mahasiswa:$nim+2025-2/kelas/jadwal/mahasiswa";
      var httpClient = HttpClient();
      var request = await httpClient.getUrl(Uri.parse(jadwalUrl));
      request.followRedirects = false; 
      request.headers.add('Cookie', cookie);

      var response = await request.close();
      
      if (response.statusCode == 302 || response.statusCode == 301) {
        service.invoke('log', {'message': '🚨 ERROR: Cookie expired! Silakan relogin.'});
        service.invoke('forceLogout'); 
        service.stopSelf();
        break;
      } else if (response.statusCode != 200) {
        service.invoke('log', {'message': '🚨 ERROR: HTTP Status ${response.statusCode}'});
        await Future.delayed(const Duration(seconds: 10));
        continue;
      }

      var responseBody = await response.transform(utf8.decoder).join();
      var document = parse(responseBody);
      bool absenAvailable = false;
      String? foundUrl;

      var links = document.querySelectorAll("a[href*='/kelas/pertemuan/']");
      
      for (var link in links) {
        var href = link.attributes['href'];
        if (href != null) {
          if (href.startsWith('/')) {
            href = domainAsli + href;
          }

          service.invoke('log', {'message': 'Mengecek detail pertemuan...'});
          
          bool adaAbsen = await _cekTandaiHadirBackground(httpClient, href, cookie, service);
          if (adaAbsen) {
            absenAvailable = true;
            foundUrl = href;
            break; 
          }
        }
      }

      if (absenAvailable) {
        service.invoke('log', {'message': '🔥 WAKTUNYA ABSEN! MEMBUNYIKAN ALARM...'});
        service.invoke('foundAbsen', {'url': foundUrl}); 
        
        if (service is AndroidServiceInstance) {
          service.setForegroundNotificationInfo(title: "🔥 ABSEN TERSEDIA!", content: "Ketuk untuk presensi ke SIX.");
        }

        const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
            'absen_channel_loud', 'SIX Absen Notifikasi Keras',
            channelDescription: 'Notifikasi untuk absen SIX ITB',
            importance: Importance.max,
            priority: Priority.high,
            ticker: 'ticker',
            playSound: true,
            enableVibration: true); 

        const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);
        await flutterLocalNotificationsPlugin.show(
            0, '🔥 ABSEN SIX ITB!', 'Tombol Tandai Hadir sudah muncul!', platformChannelSpecifics);

      } else {
        service.invoke('log', {'message': 'Aman. Belum ada tombol absen untuk saat ini.'});
      }

    } catch (e) {
      service.invoke('log', {'message': '🚨 Terjadi kesalahan: $e'});
    }

    int delayDetik = 5 + Random().nextInt(6);
    service.invoke('log', {'message': 'Menunggu $delayDetik detik ....'});
    await Future.delayed(Duration(seconds: delayDetik));
  }
}

Future<bool> _cekTandaiHadirBackground(HttpClient client, String urlPertemuan, String cookie, ServiceInstance service) async {
  try {
    var req = await client.getUrl(Uri.parse(urlPertemuan));
    req.followRedirects = false;
    req.headers.add('Cookie', cookie);
    
    var res = await req.close();
    var body = await res.transform(utf8.decoder).join();
    
    var docDetail = parse(body);
    String textContent = docDetail.body?.text ?? "";
    
    if (textContent.contains("Tandai Hadir")) {
      return true;
    }
  } catch (e) {
    service.invoke('log', {'message': 'Gagal membuka link pertemuan: $e'});
  }
  return false;
}

// ==========================================
// APLIKASI UTAMA (UI)
// ==========================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const LinuxInitializationSettings initializationSettingsLinux =
      LinuxInitializationSettings(defaultActionName: 'Buka Notifikasi');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    linux: initializationSettingsLinux,
  );
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  await initializeService();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SIX Auto Absen',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue.shade900),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}

// ==========================================
// SPLASH SCREEN
// ==========================================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _cekSesi();
  }

  Future<void> _cekSesi() async {
    final prefs = await SharedPreferences.getInstance();
    final cookie = prefs.getString('cookie_six') ?? "";

    await Future.delayed(const Duration(seconds: 1)); 

    if (!mounted) return;

    // LOGIKA PENGECEKAN LOGIN: Memeriksa keberadaan khongguan
    if (cookie.contains('khongguan=')) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const DashboardScreen()),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const LoginSIXScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}

// ==========================================
// LOGIN SCREEN
// ==========================================
class LoginSIXScreen extends StatefulWidget {
  const LoginSIXScreen({super.key});

  @override
  State<LoginSIXScreen> createState() => _LoginSIXScreenState();
}

class _LoginSIXScreenState extends State<LoginSIXScreen> {
  WebViewController? _controller;
  bool _isLoading = true;
  bool _isWebViewSupported = false;
  Timer? _loginCheckerTimer;

  final TextEditingController _nimController = TextEditingController();
  final TextEditingController _khongguanController = TextEditingController();
  final TextEditingController _nissinController = TextEditingController(text: 'ms365'); 

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  void _initWebView() {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        _isWebViewSupported = true;
        _controller = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setNavigationDelegate(
            NavigationDelegate(
              onPageFinished: (String url) {
                setState(() { _isLoading = false; });
              },
              onPageStarted: (String url) {
                setState(() { _isLoading = true; });
              },
            ),
          )
          ..loadRequest(Uri.parse('https://six.itb.ac.id'));

        // ==============================================
        // TIMER PERIODIK: Cek cookie otomatis tiap 3 detik
        // ==============================================
        _loginCheckerTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
          _periksaCookieOtomatis();
        });
      } else {
        setState(() {
          _isWebViewSupported = false;
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _isWebViewSupported = false;
        _isLoading = false;
      });
    }
  }

  Future<void> _periksaCookieOtomatis() async {
    if (_controller == null || !mounted) return;
    
    try {
      final Object cookiesObj = await _controller!.runJavaScriptReturningResult('document.cookie');
      String cookiesStr = cookiesObj.toString().replaceAll('"', '');
      String currentUrl = await _controller!.currentUrl() ?? "";

      // Deteksi login: URL berpindah ke aplikasi internal ATAU cookie khongguan muncul
      bool isLoginUrl = currentUrl.contains('/app/');
      bool hasKhongguan = cookiesStr.contains('khongguan=');

      if (isLoginUrl || hasKhongguan) {
        // Fallback jika OS menyembunyikan Cookie (HttpOnly)
        if (isLoginUrl && !hasKhongguan) {
          _loginCheckerTimer?.cancel();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Ekstraksi Cookie diblokir oleh sistem. Harap gunakan Mode Manual.'),
                duration: Duration(seconds: 5),
            ));
            setState(() { _isWebViewSupported = false; });
          }
          return;
        }

        _loginCheckerTimer?.cancel(); // Hentikan loop timer
        
        // Tambahkan nissin=ms365 otomatis jika tidak ada
        if (!cookiesStr.contains('nissin=')) {
          cookiesStr += "; nissin=ms365;";
        }

        String nim = _nimController.text.trim();

        // 1. Coba cari NIM dari URL terlebih dahulu
        RegExp urlNimRegex = RegExp(r'mahasiswa:(\d+)');
        final matchUrl = urlNimRegex.firstMatch(currentUrl);
        if (matchUrl != null) {
          nim = matchUrl.group(1)!;
        }

        // 2. Jika NIM belum dapat, coba cari dari keseluruhan teks HTML (Scraping)
        if (nim.isEmpty) {
          final Object htmlObj = await _controller!.runJavaScriptReturningResult('document.documentElement.innerText');
          RegExp textNimRegex = RegExp(r'\b([1-3][0-9]{7})\b');
          final matchText = textNimRegex.firstMatch(htmlObj.toString());
          if (matchText != null) {
            nim = matchText.group(1)!;
          }
        }

        await _simpanSesi(cookiesStr, nim);
      }
    } catch (e) {
      debugPrint("Gagal ekstrak data secara periodik: $e");
    }
  }

  Future<void> _simpanSesi(String cookie, String nim) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cookie_six', cookie);
    if (nim.isNotEmpty) await prefs.setString('nim_six', nim);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Berhasil menyimpan Sesi SIX!')),
    );

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const DashboardScreen()),
    );
  }

  Future<void> _bukaBrowserEksternal() async {
    final Uri url = Uri.parse('https://six.itb.ac.id');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gagal membuka browser.')),
      );
    }
  }

  Future<void> _manualLogin() async {
    String nim = _nimController.text.trim();
    String khongguan = _khongguanController.text.trim();
    String nissin = _nissinController.text.trim();

    if (khongguan.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Harap isi Cookie Khongguan terlebih dahulu!')),
      );
      return;
    }
    
    String cookie = "khongguan=$khongguan; nissin=$nissin;";
    await _simpanSesi(cookie, nim);
  }

  @override
  void dispose() {
    _loginCheckerTimer?.cancel();
    _nimController.dispose();
    _khongguanController.dispose();
    _nissinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Login ke SIX ITB', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.blue.shade900,
      ),
      body: _isWebViewSupported
          ? Stack(
              children: [
                if (_controller != null) WebViewWidget(controller: _controller!),
                if (_isLoading)
                  const Center(child: CircularProgressIndicator()),
              ],
            )
          : _buildManualLoginUI(), 
    );
  }

  Widget _buildManualLoginUI() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.public, size: 80, color: Colors.blueGrey),
            const SizedBox(height: 24),
            const Text(
              "Mode Eksternal Terdeteksi",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              "Buka SIX di browser untuk login, lalu periksa Developer Tools untuk menyalin Cookie Anda.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _bukaBrowserEksternal,
              icon: const Icon(Icons.open_in_browser),
              label: const Text("1. Buka SIX di Browser"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              "2. Masukkan Data Secara Manual:",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nimController,
              decoration: const InputDecoration(
                labelText: "NIM (Opsional)",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _khongguanController,
              decoration: const InputDecoration(
                labelText: "Cookie 'khongguan'",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.cookie),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nissinController,
              decoration: const InputDecoration(
                labelText: "Cookie 'nissin' (Default: ms365)",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.cookie_outlined),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _manualLogin,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade900,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text("3. Simpan Sesi & Masuk", style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 3. DASHBOARD (UI MONITORING & STATUS)
// ==========================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  String _nim = "";
  bool _isLooping = false;
  bool _isAppInForeground = true; 
  
  String _statusPresensi = "Mengecek saat ini...";
  String? _urlAbsenAktif; 
  final String _domainAsli = "https://six.itb.ac.id";

  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();

  StreamSubscription? _logSubscription;
  StreamSubscription? _absenSubscription;
  StreamSubscription? _logoutSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); 
    _loadData();
    _inisialisasiListener();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppInForeground = state == AppLifecycleState.resumed;
    // Pengecekan kilat jika aplikasi dibuka kembali
    if (_isAppInForeground) {
      _cekAbsenSekarangLangsung();
    }
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _nim = prefs.getString('nim_six') ?? "";
    });

    bool isRunning = false;
    if (Platform.isAndroid || Platform.isIOS) {
      isRunning = await FlutterBackgroundService().isRunning();
      // JIKA SERVICE BELUM BERJALAN, OTOMATIS JALANKAN SEKARANG
      if (!isRunning) {
        await _mulaiLooping();
        isRunning = true;
      }
    } else {
      if (!_isLooping) {
        _mulaiLooping();
        isRunning = true;
      }
    }
    
    setState(() {
      _isLooping = isRunning;
    });

    // Pengecekan instan sesaat setelah Dashboard terbuka
    _cekAbsenSekarangLangsung();
  }

  void _inisialisasiListener() {
    if (!Platform.isAndroid && !Platform.isIOS) return; 
    
    final service = FlutterBackgroundService();

    _logSubscription = service.on('log').listen((event) {
      if (event != null && event['message'] != null) {
        _tambahLog(event['message'].toString());
      }
    });

    _absenSubscription = service.on('foundAbsen').listen((event) {
      if (event != null && event['url'] != null) {
        setState(() {
          _urlAbsenAktif = event['url'].toString();
          _statusPresensi = "🔥 Absen Tersedia!";
        });
      }
    });

    _logoutSubscription = service.on('forceLogout').listen((event) {
      _logout(hentikanService: false); 
    });
  }

  void _tambahLog(String pesan) {
    if (!mounted) return;
    
    if (_isAppInForeground) {
      setState(() {
        _susunLog(pesan);
      });
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } else {
      _susunLog(pesan);
    }
  }

  void _susunLog(String pesan) {
    final waktu = "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}";
    _logs.add("[$waktu] $pesan");
    if (_logs.length > 200) _logs.removeAt(0); 
  }

  // ==============================================================
  // PENGECEKAN INSTAN (Jalan di Foreground saat Layar Aktif)
  // ==============================================================
  Future<void> _cekAbsenSekarangLangsung() async {
    if (!mounted) return;
    setState(() { _statusPresensi = "Mengecek saat ini..."; });
    _tambahLog("Melakukan pengecekan kilat di layar...");

    try {
      final prefs = await SharedPreferences.getInstance();
      final cookie = prefs.getString('cookie_six') ?? "";

      String jadwalUrl = "$_domainAsli/app/mahasiswa:$_nim+2025-2/kelas/jadwal/mahasiswa";
      var httpClient = HttpClient();
      var request = await httpClient.getUrl(Uri.parse(jadwalUrl));
      request.followRedirects = false; 
      request.headers.add('Cookie', cookie);

      var response = await request.close();
      
      if (response.statusCode == 302 || response.statusCode == 301) {
        _tambahLog("🚨 Pengecekan Kilat: Sesi Habis.");
        setState(() { _statusPresensi = "Sesi Berakhir"; });
        return;
      }

      var responseBody = await response.transform(utf8.decoder).join();
      var document = parse(responseBody);
      bool absenAvailable = false;
      String? foundUrl;

      var links = document.querySelectorAll("a[href*='/kelas/pertemuan/']");
      
      for (var link in links) {
        var href = link.attributes['href'];
        if (href != null) {
          if (href.startsWith('/')) href = _domainAsli + href;
          
          bool adaAbsen = await _cekTandaiHadirKecil(httpClient, href, cookie);
          if (adaAbsen) {
            absenAvailable = true;
            foundUrl = href;
            break; 
          }
        }
      }

      if (mounted) {
        setState(() { 
          _urlAbsenAktif = foundUrl; 
          _statusPresensi = absenAvailable ? "🔥 Absen Tersedia!" : "Belum Ada Absen";
        });
        _tambahLog("Hasil pengecekan kilat: $_statusPresensi");
      }
    } catch (e) {
      if (mounted) {
        setState(() { _statusPresensi = "Gagal Mengecek"; });
      }
    }
  }

  Future<bool> _cekTandaiHadirKecil(HttpClient client, String urlPertemuan, String cookie) async {
    try {
      var req = await client.getUrl(Uri.parse(urlPertemuan));
      req.followRedirects = false;
      req.headers.add('Cookie', cookie);
      
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
  // ==============================================================

  Future<void> _mulaiLooping() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final service = FlutterBackgroundService();
      await service.startService();
      setState(() { _isLooping = true; });
      _tambahLog("Service latar belakang diaktifkan.");
    } else {
      setState(() { _isLooping = true; });
      _tambahLog("Memulai pengecekan di mode Desktop LOKAL...");
      _jalankanLoopingDesktop();
    }
  }

  void _hentikanLooping() {
    if (Platform.isAndroid || Platform.isIOS) {
      final service = FlutterBackgroundService();
      service.invoke("stopService");
    }
    setState(() { _isLooping = false; });
    _tambahLog("Automasi dihentikan oleh pengguna.");
  }

  // Fallback Looping Desktop LOKAL
  Future<void> _jalankanLoopingDesktop() async {
    while (_isLooping) {
      DateTime sekarang = DateTime.now();
      int jam = sekarang.hour;

      if (jam < 8 || jam >= 16) {
        _tambahLog("💤 Jam ${jam.toString().padLeft(2, '0')}:${sekarang.minute.toString().padLeft(2, '0')} di luar jadwal. Tidur 1 jam...");
        await Future.delayed(const Duration(hours: 1));
        continue;
      }

      await _cekAbsenSekarangLangsung(); // Panggil fungsi kilat untuk Desktop
      if (_urlAbsenAktif != null) {
        _tambahLog("🔥 WAKTUNYA ABSEN! MEMBUNYIKAN ALARM...");
        final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
        const LinuxNotificationDetails linuxSpecifics = LinuxNotificationDetails();
        const NotificationDetails platformSpecifics = NotificationDetails(linux: linuxSpecifics);
        await flutterLocalNotificationsPlugin.show(
            0, '🔥 ABSEN SIX ITB!', 'Tombol Tandai Hadir sudah muncul!', platformSpecifics);
      }

      int delayDetik = 5 + Random().nextInt(6);
      _tambahLog("Menunggu $delayDetik detik ....");
      await Future.delayed(Duration(seconds: delayDetik));
    }
  }

  Future<void> _bukaHalamanAbsenExternal() async {
    if (_urlAbsenAktif == null) return;
    final Uri url = Uri.parse(_urlAbsenAktif!);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      _tambahLog("🚨 Gagal membuka browser untuk absen.");
    }
  }

  Future<void> _logout({bool hentikanService = true}) async {
    if (hentikanService) {
      _hentikanLooping();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const LoginSIXScreen()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _logSubscription?.cancel();
    _absenSubscription?.cancel();
    _logoutSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isAbsenAda = _urlAbsenAktif != null;

    return Scaffold(
      appBar: AppBar(
        title: Text('Dasbor Absen ($_nim)', style: const TextStyle(color: Colors.white, fontSize: 18)),
        backgroundColor: Colors.blue.shade900,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () => _cekAbsenSekarangLangsung(),
            tooltip: "Cek Ulang Manual",
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            onPressed: () => _logout(),
            tooltip: "Logout & Hapus Sesi",
          )
        ],
      ),
      body: Column(
        children: [
          // 1. Status Background Service
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            color: Colors.blue.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Status Automasi:", style: TextStyle(fontWeight: FontWeight.bold)),
                Row(
                  children: [
                    Icon(
                      _isLooping ? Icons.check_circle : Icons.pause_circle, 
                      color: _isLooping ? Colors.green : Colors.red,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(_isLooping ? (Platform.isAndroid || Platform.isIOS ? "Berjalan di Latar" : "Berjalan Lokal") : "Berhenti", 
                      style: TextStyle(
                        fontWeight: FontWeight.bold, 
                        color: _isLooping ? Colors.green : Colors.red,
                        fontSize: 12
                      )
                    ),
                  ],
                )
              ],
            ),
          ),

          // 2. Tampilan Status Absen Saat Ini
          Container(
            margin: const EdgeInsets.all(16.0),
            padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
            width: double.infinity,
            decoration: BoxDecoration(
              color: isAbsenAda ? Colors.green.shade100 : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isAbsenAda ? Colors.green : Colors.grey.shade400,
                width: 2
              ),
            ),
            child: Column(
              children: [
                const Text("STATUS KEHADIRAN", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black54)),
                const SizedBox(height: 8),
                Text(
                  _statusPresensi,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24, 
                    fontWeight: FontWeight.bold, 
                    color: isAbsenAda ? Colors.green.shade800 : Colors.black87
                  ),
                ),
              ],
            ),
          ),
          
          // 3. Tombol Buka Halaman Hadir
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: ElevatedButton.icon(
              onPressed: isAbsenAda ? _bukaHalamanAbsenExternal : null,
              icon: const Icon(Icons.assignment_turned_in),
              label: Text(
                isAbsenAda ? "Presensi ke SIX Sekarang" : "Belum Ada Absen Tersedia",
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 55),
                backgroundColor: Colors.green.shade600,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade300,
                disabledForegroundColor: Colors.grey.shade600,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 4. Area Logger
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Text(
                      _logs[index],
                      style: const TextStyle(
                        color: Colors.greenAccent, 
                        fontFamily: 'monospace',
                        fontSize: 12
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          
          // 5. Kontrol Mulai/Berhenti Background
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: _isLooping ? null : () {
                    _mulaiLooping();
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text("Mulai Auto"),
                ),
                ElevatedButton.icon(
                  onPressed: _isLooping ? () {
                    _hentikanLooping();
                  } : null,
                  icon: const Icon(Icons.stop),
                  label: const Text("Berhenti"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade100),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}
