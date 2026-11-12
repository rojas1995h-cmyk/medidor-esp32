import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );

  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  // Canal de notificación de alta prioridad en Android
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'corte_ciclo_channel',
    'Alertas de Facturación y Corte',
    description: 'Disparos automáticos al cumplirse el ciclo de 30 días',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
      flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  if (androidPlugin != null) {
    await androidPlugin.createNotificationChannel(channel);
    await androidPlugin.requestNotificationsPermission();
  }

  runApp(const SmartEnergyApp());
}

class SmartEnergyApp extends StatelessWidget {
  const SmartEnergyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Medidor Inteligente',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF070A11),
        fontFamily: 'sans-serif',
      ),
      home: const MainScreen(),
    );
  }
}

// ==========================================================
// MODELOS DE DATOS
// ==========================================================
class DptoModel {
  final bool rele;
  final double corriente;
  final double potencia;
  final double energia;
  final double monto;
  final bool mesFinalizado;

  DptoModel({
    required this.rele,
    required this.corriente,
    required this.potencia,
    required this.energia,
    required this.monto,
    required this.mesFinalizado,
  });

  factory DptoModel.fromJson(Map<String, dynamic> json) {
    return DptoModel(
      rele: json['rele'] ?? false,
      corriente: (json['corriente'] as num?)?.toDouble() ?? 0.0,
      potencia: (json['potencia'] as num?)?.toDouble() ?? 0.0,
      energia: (json['energia'] as num?)?.toDouble() ?? 0.0,
      monto: (json['monto'] as num?)?.toDouble() ?? 0.0,
      mesFinalizado: json['mesFinalizado'] ?? false,
    );
  }

  factory DptoModel.initial() => DptoModel(
        rele: false,
        corriente: 0.0,
        potencia: 0.0,
        energia: 0.0,
        monto: 0.0,
        mesFinalizado: false,
      );
}

class StatusModel {
  final String hora;
  final int dia;
  final bool hayRed;
  final double vRed;
  final bool sistemaEncendido;
  final double pTotal;
  final double montoTotal;
  final bool alertaBuzzer;
  final DptoModel dpto1;
  final DptoModel dpto2;

  StatusModel({
    required this.hora,
    required this.dia,
    required this.hayRed,
    required this.vRed,
    required this.sistemaEncendido,
    required this.pTotal,
    required this.montoTotal,
    required this.alertaBuzzer,
    required this.dpto1,
    required this.dpto2,
  });

  factory StatusModel.fromJson(Map<String, dynamic> json) {
    return StatusModel(
      hora: json['hora'] ?? '--:--:--',
      dia: json['dia'] ?? 1,
      hayRed: json['hayRed'] ?? false,
      vRed: (json['vRed'] as num?)?.toDouble() ?? 0.0,
      sistemaEncendido: json['sistemaEncendido'] ?? false,
      pTotal: (json['pTotal'] as num?)?.toDouble() ?? 0.0,
      montoTotal: (json['montoTotal'] as num?)?.toDouble() ?? 0.0,
      alertaBuzzer: json['alertaBuzzer'] ?? false,
      dpto1: DptoModel.fromJson(json['dpto1'] ?? {}),
      dpto2: DptoModel.fromJson(json['dpto2'] ?? {}),
    );
  }

  factory StatusModel.initial() => StatusModel(
        hora: '--:--:--',
        dia: 1,
        hayRed: false,
        vRed: 0.0,
        sistemaEncendido: false,
        pTotal: 0.0,
        montoTotal: 0.0,
        alertaBuzzer: false,
        dpto1: DptoModel.initial(),
        dpto2: DptoModel.initial(),
      );
}

// ==========================================================
// SERVICIO API REST (ESP32 SOFT-AP)
// ==========================================================
class Esp32Service {
  static const String baseUrl = 'http://192.168.4.1/api';

  static Future<StatusModel?> fetchStatus() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/status'))
          .timeout(const Duration(milliseconds: 750));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return StatusModel.fromJson(data);
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> sendControl(String accion) async {
    try {
      final response = await http
          .post(Uri.parse('$baseUrl/control?accion=$accion'))
          .timeout(const Duration(milliseconds: 900));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

// ==========================================================
// PANTALLA PRINCIPAL
// ==========================================================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  Timer? _pollingTimer;
  StatusModel _status = StatusModel.initial();
  bool _isConnected = false;

  bool _notificacionEnviadaDpto1 = false;
  bool _notificacionEnviadaDpto2 = false;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final newStatus = await Esp32Service.fetchStatus();
      if (!mounted) return;

      if (newStatus != null) {
        setState(() {
          _status = newStatus;
          _isConnected = true;
        });
        _evaluarNotificaciones(newStatus);
      } else {
        if (_isConnected) {
          setState(() {
            _isConnected = false;
          });
        }
      }
    });
  }

  void _evaluarNotificaciones(StatusModel s) {
    if (s.dpto1.mesFinalizado) {
      if (!_notificacionEnviadaDpto1) {
        _dispararNotificacionLocal(
          id: 1,
          titulo: '⚠️ Fin de Ciclo (30 Días) - Dpto 1',
          cuerpo:
              'Corte automático aplicado en Dpto 1. Monto a liquidar: S/. ${s.dpto1.monto.toStringAsFixed(2)}',
        );
        _notificacionEnviadaDpto1 = true;
      }
    } else {
      _notificacionEnviadaDpto1 = false;
    }

    if (s.dpto2.mesFinalizado) {
      if (!_notificacionEnviadaDpto2) {
        _dispararNotificacionLocal(
          id: 2,
          titulo: '⚠️ Fin de Ciclo (30 Días) - Dpto 2',
          cuerpo:
              'Corte automático aplicado en Dpto 2. Monto a liquidar: S/. ${s.dpto2.monto.toStringAsFixed(2)}',
        );
        _notificacionEnviadaDpto2 = true;
      }
    } else {
      _notificacionEnviadaDpto2 = false;
    }
  }

  Future<void> _dispararNotificacionLocal({
    required int id,
    required String titulo,
    required String cuerpo,
  }) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'corte_ciclo_channel',
      'Alertas de Facturación y Corte',
      channelDescription: 'Disparos automáticos al cumplirse el ciclo de 30 días',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
      playSound: true,
      enableVibration: true,
    );

    const NotificationDetails generalNotificationDetails = NotificationDetails(
      android: androidDetails,
    );

    await flutterLocalNotificationsPlugin.show(
      id,
      titulo,
      cuerpo,
      generalNotificationDetails,
    );
  }

  Future<void> _ejecutarComando(String accion) async {
    final ok = await Esp32Service.sendControl(accion);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error al enviar comando al ESP32. Verifica conexión Wi-Fi.'),
          backgroundColor: Color(0xFFFF1744),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _mostrarDialogoConfirmacion({
    required String titulo,
    required String mensaje,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141A29),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFF29354D)),
        ),
        title: Text(
          titulo,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          mensaje,
          style: const TextStyle(color: Color(0xFFB0BEC5), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCELAR', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E676),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              onConfirm();
            },
            child: const Text('CONFIRMAR', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _mostrarModalPagoExitoso({
    required String linea1,
    required String linea2,
    required String linea3,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Color(0xFF00E676),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, color: Colors.black, size: 60),
            const SizedBox(height: 12),
            Text(
              linea1,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              linea2,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              linea3,
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: const Color(0xFF00E676),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ACEPTAR', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildPersistentHeader(),
            if (_status.alertaBuzzer ||
                _status.dpto1.mesFinalizado ||
                _status.dpto2.mesFinalizado)
              _buildBlinkingAlertBanner(),
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: [
                  _buildVistaPanelGeneral(),
                  _buildVistaDptoRecibo(dptoId: 1),
                  _buildVistaDptoRecibo(dptoId: 2),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0B0F19),
          border: Border(top: BorderSide(color: Color(0xFF1E283D), width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: const Color(0xFF00E676),
          unselectedItemColor: const Color(0xFF60728F),
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          onTap: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard),
              label: 'General',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.bolt_outlined),
              activeIcon: Icon(Icons.bolt),
              label: 'Dpto 1',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.flash_on_outlined),
              activeIcon: Icon(Icons.flash_on),
              label: 'Dpto 2',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPersistentHeader() {
    final double progresoCiclo = (_status.dia / 30.0).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF0B0F19),
        border: Border(bottom: BorderSide(color: Color(0xFF1C2436), width: 1)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _isConnected
                      ? const Color(0xFF00E676).withOpacity(0.12)
                      : const Color(0xFFFF1
