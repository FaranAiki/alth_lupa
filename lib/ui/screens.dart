import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../core/services.dart';  

// ==========================================
// 1. SPLASH SCREEN
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
    final session = await StorageService().getSession();
    await Future.delayed(const Duration(seconds: 1)); 
    if (!mounted) return;

    if (session['cookie']!.contains('khongguan=') && session['nim']!.isNotEmpty) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const DashboardScreen()));
    } else {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const LoginSIXScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

// ==========================================
// 2. LOGIN SCREEN
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
    if (Platform.isAndroid || Platform.isIOS) {
      _isWebViewSupported = true;
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setUserAgent(AppConstants.userAgent)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) { if (mounted) setState(() { _isLoading = false; }); },
            onPageStarted: (_) { if (mounted) setState(() { _isLoading = true; }); },
          ),
        )..loadRequest(Uri.parse('https://six.itb.ac.id'));

      _loginCheckerTimer = Timer.periodic(const Duration(seconds: 3), (_) => _periksaCookieOtomatis());
    } else {
      _isWebViewSupported = false;
      _isLoading = false;
    }
  }

  Future<void> _periksaCookieOtomatis() async {
    if (_controller == null || !mounted) return;
    try {
      final Object cookiesObj = await _controller!.runJavaScriptReturningResult('document.cookie');
      String cookiesStr = cookiesObj.toString().replaceAll('"', '');
      String currentUrl = await _controller!.currentUrl() ?? "";

      bool isLoginUrl = currentUrl.contains('/app/');
      bool hasKhongguan = cookiesStr.contains('khongguan=');

      if (isLoginUrl || hasKhongguan) {
        if (isLoginUrl && !hasKhongguan) {
          _loginCheckerTimer?.cancel();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ekstraksi Cookie diblokir OS. Harap gunakan Mode Manual.')));
            setState(() { _isWebViewSupported = false; });
          }
          return;
        }

        String nim = _nimController.text.trim();
        RegExp urlNimRegex = RegExp(r'mahasiswa:(\d+)');
        final matchUrl = urlNimRegex.firstMatch(currentUrl);
        if (matchUrl != null) nim = matchUrl.group(1)!;

        if (nim.isEmpty) {
          final Object htmlObj = await _controller!.runJavaScriptReturningResult('document.documentElement.innerText');
          RegExp textNimRegex = RegExp(r'\b([1-3][0-9]{7})\b');
          final matchText = textNimRegex.firstMatch(htmlObj.toString());
          if (matchText != null) nim = matchText.group(1)!;
        }

        if (nim.isNotEmpty) {
          _loginCheckerTimer?.cancel(); 
          if (!cookiesStr.contains('nissin=')) {
            if (cookiesStr.isNotEmpty && !cookiesStr.trim().endsWith(';')) cookiesStr += ';';
            cookiesStr += " nissin=ms365;";
          }
          await _simpanSesi(cookiesStr, nim);
        }
      }
    } catch (e) {
      debugPrint("Gagal ekstrak cookie periodik: $e");
    }
  }

  Future<void> _simpanSesi(String cookie, String nim) async {
    await StorageService().saveSession(cookie, nim);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sesi SIX Berhasil Disimpan!')));
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const DashboardScreen()));
  }

  Future<void> _bukaBrowserEksternal() async {
    final Uri url = Uri.parse('https://six.itb.ac.id');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Gagal membuka browser.')));
    }
  }

  Future<void> _manualLogin() async {
    String nim = _nimController.text.trim();
    String khongguan = _khongguanController.text.trim();
    String nissin = _nissinController.text.trim();

    if (khongguan.isEmpty || nim.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('NIM dan Cookie Khongguan wajib diisi!')));
      return;
    }
    await _simpanSesi("khongguan=$khongguan; nissin=$nissin;", nim);
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
      appBar: AppBar(title: const Text('Login ke SIX', style: TextStyle(color: Colors.white)), backgroundColor: Colors.blue.shade900),
      body: _isWebViewSupported
          ? Stack(
              children: [
                if (_controller != null) WebViewWidget(controller: _controller!),
                if (_isLoading) const Center(child: CircularProgressIndicator()),
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.public, size: 80, color: Colors.blueGrey),
            const SizedBox(height: 24),
            const Text("Mode Eksternal Terdeteksi", textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _bukaBrowserEksternal,
              icon: const Icon(Icons.open_in_browser), label: const Text("Buka SIX di Browser"),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
            ),
            const SizedBox(height: 24),
            TextField(controller: _nimController, decoration: const InputDecoration(labelText: "NIM Wajib", border: OutlineInputBorder(), prefixIcon: Icon(Icons.person)), keyboardType: TextInputType.number),
            const SizedBox(height: 16),
            TextField(controller: _khongguanController, decoration: const InputDecoration(labelText: "Cookie 'khongguan'", border: OutlineInputBorder(), prefixIcon: Icon(Icons.cookie))),
            const SizedBox(height: 16),
            TextField(controller: _nissinController, decoration: const InputDecoration(labelText: "Cookie 'nissin' (Default: ms365)", border: OutlineInputBorder(), prefixIcon: Icon(Icons.cookie_outlined))),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _manualLogin,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade900, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
              child: const Text("Simpan Sesi & Masuk", style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 3. DASHBOARD SCREEN
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
    if (_isAppInForeground) _cekAbsenSekarangLangsung();
  }

  Future<void> _loadData() async {
    final session = await StorageService().getSession();
    setState(() { _nim = session['nim']!; });

    bool isRunning = false;
    if (Platform.isAndroid || Platform.isIOS) {
      isRunning = await FlutterBackgroundService().isRunning();
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
    
    setState(() { _isLooping = isRunning; });
    _cekAbsenSekarangLangsung();
  }

  void _inisialisasiListener() {
    if (!Platform.isAndroid && !Platform.isIOS) return; 
    final service = FlutterBackgroundService();

    _logSubscription = service.on('log').listen((event) {
      if (event != null && event['message'] != null) _tambahLog(event['message'].toString());
    });
    _absenSubscription = service.on('foundAbsen').listen((event) {
      if (event != null && event['url'] != null) {
        setState(() { _urlAbsenAktif = event['url'].toString(); _statusPresensi = "🔥 Absen Tersedia!"; });
      }
    });
    _logoutSubscription = service.on('forceLogout').listen((event) { _logout(hentikanService: false); });
  }

  void _tambahLog(String pesan) {
    if (!mounted) return;
    if (_isAppInForeground) {
      setState(() { _susunLog(pesan); });
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
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

  // ===========================================
  // Integrasi SOLID: Panggil ApiService dari UI
  // ===========================================
  Future<void> _cekAbsenSekarangLangsung() async {
    if (!mounted) return;
    setState(() { _statusPresensi = "Mengecek kalender saat ini..."; });
    _tambahLog("Melakukan pembacaan kalender (Foreground)...");

    final session = await StorageService().getSession();
    final result = await ApiService().checkJadwal(session['nim']!, session['cookie']!, null);
    
    if (!mounted) return;

    if (result['status'] == 'expired') {
      _tambahLog("🚨 ${result['message']}");
      setState(() { _statusPresensi = "Sesi Berakhir"; });
    } else if (result['status'] == 'found') {
      setState(() { 
        _urlAbsenAktif = result['url']; 
        _statusPresensi = "🔥 Absen Tersedia!";
      });
      _tambahLog("🔥 TERSEDIA: ${result['matkul']}");
    } else {
      setState(() { _statusPresensi = "Belum Ada Absen"; });
      _tambahLog(result['message']);
    }
  }

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
      FlutterBackgroundService().invoke("stopService");
    }
    setState(() { _isLooping = false; });
    _tambahLog("Automasi dihentikan oleh pengguna.");
  }

  Future<void> _jalankanLoopingDesktop() async {
    while (_isLooping) {
      DateTime sekarang = DateTime.now();
      if (sekarang.hour < 8 || sekarang.hour >= 16) {
        _tambahLog("💤 Di luar jadwal. Tidur 1 jam...");
        await Future.delayed(const Duration(hours: 1));
        continue;
      }
      await _cekAbsenSekarangLangsung(); 
      if (_urlAbsenAktif != null) await NotificationService().showAlarm('🔥 ABSEN SIX ITB!', 'Tombol Tandai Hadir sudah muncul!');
      await Future.delayed(Duration(seconds: 5 + Random().nextInt(6)));
    }
  }

  Future<void> _bukaHalamanAbsenExternal() async {
    if (_urlAbsenAktif == null) return;
    if (!await launchUrl(Uri.parse(_urlAbsenAktif!), mode: LaunchMode.externalApplication)) {
      _tambahLog("🚨 Gagal membuka browser untuk absen.");
    }
  }

  Future<void> _logout({bool hentikanService = true}) async {
    if (hentikanService) _hentikanLooping();
    await StorageService().clearSession();
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const LoginSIXScreen()));
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
          IconButton(icon: const Icon(Icons.refresh, color: Colors.white), onPressed: () => _cekAbsenSekarangLangsung(), tooltip: "Cek Manual"),
          IconButton(icon: const Icon(Icons.logout, color: Colors.white), onPressed: () => _logout(), tooltip: "Logout")
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0), color: Colors.blue.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Status Automasi:", style: TextStyle(fontWeight: FontWeight.bold)),
                Row(
                  children: [
                    Icon(_isLooping ? Icons.check_circle : Icons.pause_circle, color: _isLooping ? Colors.green : Colors.red, size: 18),
                    const SizedBox(width: 8),
                    Text(_isLooping ? (Platform.isAndroid || Platform.isIOS ? "Berjalan di Latar" : "Berjalan Lokal") : "Berhenti", style: TextStyle(fontWeight: FontWeight.bold, color: _isLooping ? Colors.green : Colors.red, fontSize: 12)),
                  ],
                )
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.all(16.0), padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
            width: double.infinity, decoration: BoxDecoration(color: isAbsenAda ? Colors.green.shade100 : Colors.grey.shade200, borderRadius: BorderRadius.circular(16), border: Border.all(color: isAbsenAda ? Colors.green : Colors.grey.shade400, width: 2)),
            child: Column(
              children: [
                const Text("STATUS KEHADIRAN", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black54)),
                const SizedBox(height: 8),
                Text(_statusPresensi, textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: isAbsenAda ? Colors.green.shade800 : Colors.black87)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: ElevatedButton.icon(
              onPressed: isAbsenAda ? _bukaHalamanAbsenExternal : null,
              icon: const Icon(Icons.assignment_turned_in),
              label: Text(isAbsenAda ? "Presensi ke SIX Sekarang" : "Belum Ada Absen", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 55), backgroundColor: Colors.green.shade600, foregroundColor: Colors.white, disabledBackgroundColor: Colors.grey.shade300, disabledForegroundColor: Colors.grey.shade600, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16), padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
              child: ListView.builder(
                controller: _scrollController, itemCount: _logs.length,
                itemBuilder: (context, index) => Padding(padding: const EdgeInsets.symmetric(vertical: 4.0), child: Text(_logs[index], style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 12))),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(onPressed: _isLooping ? null : () => _mulaiLooping(), icon: const Icon(Icons.play_arrow), label: const Text("Mulai Auto")),
                ElevatedButton.icon(onPressed: _isLooping ? () => _hentikanLooping() : null, icon: const Icon(Icons.stop), label: const Text("Berhenti"), style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade100)),
              ],
            ),
          )
        ],
      ),
    );
  }
}
