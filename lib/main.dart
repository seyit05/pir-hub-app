import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

const String kDefaultServerUrl = 'https://seyitahmetkaris.com.tr';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PirHubApp());
}

class PirHubApp extends StatelessWidget {
  const PirHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1ABC9C),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1ABC9C),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'PIR Hub',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: scheme.surface,
        cardTheme: CardThemeData(
          elevation: 0,
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surfaceContainerHigh,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: darkScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: darkScheme.surface,
        cardTheme: CardThemeData(
          elevation: 0,
          color: darkScheme.surfaceContainerHighest.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: darkScheme.surfaceContainerHigh,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

Uri _parseHttpRoot(String raw) {
  var s = raw.trim();
  if (s.isEmpty) s = kDefaultServerUrl;
  if (!s.contains('://')) {
    s = s.startsWith('localhost') || s.startsWith('192.168.') || s.startsWith('10.')
        ? 'http://$s'
        : 'https://$s';
  }
  return Uri.parse(s);
}

Uri _wsUriFromHttpRoot(Uri httpRoot) {
  final scheme = httpRoot.scheme == 'https' ? 'wss' : 'ws';
  var path = httpRoot.path;
  if (path.isEmpty || path == '/') {
    path = '/ws';
  } else {
    path = path.endsWith('/') ? '${path}ws' : '$path/ws';
  }
  return Uri(
    scheme: scheme,
    userInfo: httpRoot.userInfo,
    host: httpRoot.host,
    port: httpRoot.port,
    path: path,
    query: httpRoot.query.isEmpty ? null : httpRoot.query,
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _baseUrlCtrl = TextEditingController(text: kDefaultServerUrl);
  final _apiKeyCtrl = TextEditingController();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _reconnectTimer;
  final _events = <String>[];
  bool _motorBusy = false;
  String _wsStatus = 'Bağlı değil';

  int _previewSession = 0;
  Uint8List? _lastJpeg;
  bool _previewOn = false;
  String? _previewError;
  StreamSubscription<List<int>>? _mjpegSub;
  http.Client? _mjpegClient;

  bool _motionActive = false;
  DateTime? _lastMotionAt;
  Timer? _motionFlashTimer;

  Uri get _httpRoot => _parseHttpRoot(_baseUrlCtrl.text);

  Uri _api(String path) {
    final p = path.startsWith('/') ? path.substring(1) : path;
    return _httpRoot.resolve(p);
  }

  Uri get _wsUri {
    var u = _wsUriFromHttpRoot(_httpRoot);
    final k = _apiKeyCtrl.text.trim();
    if (k.isEmpty) return u;
    final merged = Map<String, String>.from(u.queryParameters);
    merged['token'] = k;
    return u.replace(queryParameters: merged);
  }

  Map<String, String> get _httpHeaders {
    final k = _apiKeyCtrl.text.trim();
    if (k.isEmpty) return {};
    return {'X-API-Key': k};
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _connectWs();
    });
  }

  @override
  void dispose() {
    _stopPreview();
    _disconnectWs();
    _reconnectTimer?.cancel();
    _motionFlashTimer?.cancel();
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  void _stopPreview() {
    _previewSession++;
    _mjpegSub?.cancel();
    _mjpegSub = null;
    _mjpegClient?.close();
    _mjpegClient = null;
    if (!mounted) return;
    setState(() {
      _previewOn = false;
      _previewError = null;
    });
  }

  Future<void> _startPreview() async {
    _mjpegSub?.cancel();
    _mjpegClient?.close();
    _previewSession++;
    final mySession = _previewSession;
    setState(() {
      _previewOn = true;
      _previewError = null;
    });

    final client = http.Client();
    _mjpegClient = client;

    try {
      final req = http.Request('GET', _api('camera/stream'));
      _httpHeaders.forEach((k, v) => req.headers[k] = v);
      req.headers['Accept'] = 'multipart/x-mixed-replace';
      final resp = await client.send(req).timeout(const Duration(seconds: 15));

      if (mySession != _previewSession || !mounted) {
        client.close();
        return;
      }
      if (resp.statusCode != 200) {
        if (mounted) {
          setState(() => _previewError = 'Sunucu hatası (${resp.statusCode})');
        }
        return;
      }

      final buffer = BytesBuilder(copy: false);
      _mjpegSub = resp.stream.listen(
        (chunk) {
          if (mySession != _previewSession) return;
          buffer.add(chunk);
          final data = buffer.toBytes();
          int startIdx = -1;
          int endIdx = -1;
          for (var i = 0; i < data.length - 1; i++) {
            if (startIdx < 0 && data[i] == 0xFF && data[i + 1] == 0xD8) {
              startIdx = i;
            } else if (startIdx >= 0 && data[i] == 0xFF && data[i + 1] == 0xD9) {
              endIdx = i + 2;
              break;
            }
          }
          if (startIdx >= 0 && endIdx > startIdx) {
            final jpeg = Uint8List.fromList(data.sublist(startIdx, endIdx));
            final tail = data.sublist(endIdx);
            buffer.clear();
            buffer.add(tail);
            if (mounted && _previewOn && mySession == _previewSession) {
              setState(() {
                _lastJpeg = jpeg;
                _previewError = null;
              });
            }
          } else if (data.length > 2 * 1024 * 1024) {
            // Hatalı veri birikti, sıfırla.
            buffer.clear();
          }
        },
        onError: (_) {
          if (mySession != _previewSession || !mounted) return;
          setState(() => _previewError = 'Bağlantı kesildi');
        },
        onDone: () {
          if (mySession != _previewSession || !mounted) return;
          if (_previewOn) {
            setState(() => _previewError = 'Akış kapandı');
          }
        },
        cancelOnError: false,
      );
    } catch (_) {
      if (mySession != _previewSession || !mounted) return;
      setState(() {
        _previewError = 'Bağlantı hatası';
      });
    }
  }

  void _disconnectWs() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _wsSub?.cancel();
    _wsSub = null;
    _channel?.sink.close();
    _channel = null;
    if (mounted) setState(() => _wsStatus = 'Bağlı değil');
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) _connectWs();
    });
  }

  void _handleMotionEvent(String type) {
    if (type == 'motion') {
      _motionFlashTimer?.cancel();
      setState(() {
        _motionActive = true;
        _lastMotionAt = DateTime.now();
      });
      _motionFlashTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) setState(() => _motionActive = false);
      });
    } else if (type == 'clear') {
      _motionFlashTimer?.cancel();
      _motionFlashTimer = Timer(const Duration(seconds: 1), () {
        if (mounted) setState(() => _motionActive = false);
      });
    }
  }

  Future<void> _connectWs() async {
    _disconnectWs();
    setState(() => _wsStatus = 'Bağlanıyor...');
    try {
      final ch = WebSocketChannel.connect(_wsUri);
      _channel = ch;
      _wsSub = ch.stream.listen(
        (data) {
          if (!mounted) return;
          final line = data is String ? data : utf8.decode(data as List<int>);
          try {
            final map = jsonDecode(line) as Map<String, dynamic>;
            final t = map['type']?.toString() ?? 'event';
            _handleMotionEvent(t);
            setState(() {
              _events.insert(0, '${_fmtNow()}  $t');
              if (_events.length > 50) _events.removeLast();
            });
          } catch (_) {
            setState(() => _events.insert(0, line));
          }
        },
        onError: (_) {
          if (!mounted) return;
          setState(() => _wsStatus = 'Hata');
          _scheduleReconnect();
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _wsStatus = 'Koptu');
          _scheduleReconnect();
        },
      );
      setState(() => _wsStatus = 'Bağlı');
    } catch (e) {
      setState(() => _wsStatus = 'Bağlantı başarısız');
      _scheduleReconnect();
    }
  }

  String _fmtNow() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
  }

  Future<void> _runMotor() async {
    if (_motorBusy) return;
    setState(() => _motorBusy = true);
    try {
      final r = await http
          .post(_api('motor/run'), headers: _httpHeaders)
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (r.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Motor komutu tamamlandı.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sunucu: ${r.statusCode} ${r.body}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('İstek hatası: $e')),
      );
    } finally {
      if (mounted) setState(() => _motorBusy = false);
    }
  }

  Future<void> _pingHealth() async {
    try {
      final r = await http
          .get(_api('health'), headers: _httpHeaders)
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Health: ${r.statusCode} ${r.body}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Health hatası: $e')),
      );
    }
  }

  String _fmtTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Color _wsColor(ColorScheme scheme) {
    switch (_wsStatus) {
      case 'Bağlı':
        return Colors.green;
      case 'Bağlanıyor...':
        return Colors.orange;
      case 'Bağlı değil':
      case 'Koptu':
      case 'Hata':
      case 'Bağlantı başarısız':
        return scheme.error;
      default:
        return scheme.onSurfaceVariant;
    }
  }

  Widget _motionCard(ColorScheme scheme) {
    final activeColor = const Color(0xFF22C55E);
    final dotColor = _motionActive ? activeColor : scheme.outlineVariant;
    final glow = _motionActive
        ? [
            BoxShadow(
              color: activeColor.withValues(alpha: 0.55),
              blurRadius: 24,
              spreadRadius: 6,
            ),
          ]
        : <BoxShadow>[];
    final title = _motionActive ? 'Hareket Algılandı' : 'PIR Sakin';
    final subtitle = _lastMotionAt == null
        ? 'Henüz hareket bildirilmedi'
        : 'Son hareket: ${_fmtTime(_lastMotionAt!)}';
    final bg = _motionActive
        ? activeColor.withValues(alpha: 0.10)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.5);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _motionActive
              ? activeColor.withValues(alpha: 0.4)
              : scheme.outlineVariant.withValues(alpha: 0.4),
          width: 1.2,
        ),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              boxShadow: glow,
            ),
            child: Icon(
              _motionActive ? Icons.sensors : Icons.sensors_off,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: _motionActive ? activeColor : scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Column(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: _wsColor(scheme),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(height: 4),
              Text(_wsStatus,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  )),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({required Widget child, EdgeInsetsGeometry? padding}) {
    return Card(
      child: Padding(
        padding: padding ?? const EdgeInsets.all(16),
        child: child,
      ),
    );
  }

  Widget _cameraCard(ColorScheme scheme) {
    return _sectionCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.videocam, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Kamera',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
              const Spacer(),
              if (_previewOn)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text('CANLI',
                          style: TextStyle(
                            color: Colors.red,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          )),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                color: Colors.black,
                child: _lastJpeg != null
                    ? Image.memory(_lastJpeg!, gaplessPlayback: true, fit: BoxFit.cover)
                    : Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.videocam_off,
                                color: Colors.white.withValues(alpha: 0.6), size: 42),
                            const SizedBox(height: 8),
                            Text(
                              _previewError ??
                                  (_previewOn ? 'Bağlanılıyor…' : 'Kamera kapalı'),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _previewOn ? null : _startPreview,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Kamera Aç'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _previewOn ? _stopPreview : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Kamera Kapa'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _motorCard(ColorScheme scheme) {
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.settings_input_component, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Motor Kontrolü',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              onPressed: _motorBusy ? null : _runMotor,
              icon: _motorBusy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.bolt),
              label: Text(_motorBusy ? 'Çalışıyor…' : 'Motoru Çalıştır'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _serverCard(ColorScheme scheme) {
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.dns_outlined, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Sunucu',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrlCtrl,
            decoration: const InputDecoration(
              labelText: 'Sunucu adresi',
              hintText: kDefaultServerUrl,
              prefixIcon: Icon(Icons.link),
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _connectWs(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _apiKeyCtrl,
            decoration: const InputDecoration(
              labelText: 'API anahtarı (varsa)',
              prefixIcon: Icon(Icons.vpn_key_outlined),
            ),
            obscureText: true,
            autocorrect: false,
            onSubmitted: (_) => _connectWs(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _pingHealth,
                icon: const Icon(Icons.health_and_safety_outlined),
                label: const Text('Health'),
              ),
              OutlinedButton.icon(
                onPressed: _connectWs,
                icon: const Icon(Icons.refresh),
                label: const Text('Yeniden bağlan'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _eventsCard(ColorScheme scheme) {
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.list_alt, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Olay Akışı',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
              const Spacer(),
              if (_events.isNotEmpty)
                IconButton(
                  tooltip: 'Temizle',
                  onPressed: () => setState(() => _events.clear()),
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
            ],
          ),
          const SizedBox(height: 4),
          if (_events.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('Henüz olay yok',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            )
          else
            ..._events.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      e.contains('motion')
                          ? Icons.directions_run
                          : e.contains('clear')
                              ? Icons.do_not_disturb_on_outlined
                              : Icons.fiber_manual_record,
                      size: 16,
                      color: e.contains('motion')
                          ? Colors.green
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        e,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('PIR Hub'),
        centerTitle: false,
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(Icons.shield_moon_outlined, color: scheme.primary),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _motionCard(scheme),
          const SizedBox(height: 12),
          _cameraCard(scheme),
          const SizedBox(height: 12),
          _motorCard(scheme),
          const SizedBox(height: 12),
          _serverCard(scheme),
          const SizedBox(height: 12),
          _eventsCard(scheme),
        ],
      ),
    );
  }
}
