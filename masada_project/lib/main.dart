import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MasadaEvApp());
}

class MasadaEvApp extends StatelessWidget {
  const MasadaEvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D0F12),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DrivingSample {
  final double powerKw;
  final double estimatedSpeedKmh;
  _DrivingSample(this.powerKw, this.estimatedSpeedKmh);
}

class _DashboardScreenState extends State<DashboardScreen> {
  // 상태 변수들
  bool _isCampingMode = false;
  static const double _batteryTotalKwh = 38.7;
  BluetoothConnection? _connection;
  bool _isConnected = false;
  bool _isConnecting = false;
  final List<int> _rxBuffer = [];
  Timer? _autoConnectTimer;

  // 데이터
  double _soc = 87.0;
  double _voltage = 318.0;
  double _current = 1.0;
  double _powerKw = 0.3;
  double _chargePowerKw = 0.0;
  double _batteryTemp = 30.0;
  int _soh = 94;
  double _bmsDistance = 185.2;
  
  final List<_DrivingSample> _recent3MinSamples = [];
  double _recent3MinEfficiency = 5.7;
  int _efficiencyScore = 50;
  
  double _accumulatedRegenKwh = 0.0;
  double _driveEnergyKwh = 0.0;
  double _hvacEnergyKwh = 0.0;
  int _drivingSeconds = 0;
  Timer? _drivingTimer;

  @override
  void initState() {
    super.initState();
    _startDrivingTimer();
    
    // [핵심] 10초 주기 자동 재연결 로직 복구
    _autoConnectTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (!_isConnected && !_isConnecting) {
        _connectToLogger();
      }
    });
  }

  // 연결 시도 시 이전 소켓 정리 및 재연결
  Future<void> _connectToLogger() async {
    if (_isConnected || _isConnecting) return;
    setState(() => _isConnecting = true);

    try {
      // 1. 이전 소켓 강제 종료
      if (_connection != null) {
        await _connection?.close();
        _connection = null;
      }

      List<BluetoothDevice> devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      BluetoothDevice? targetDevice;

      // 마사다/OBD 기기 검색
      for (var d in devices) {
        String name = (d.name ?? '').toUpperCase();
        if (name.contains('EV') || name.contains('OBD') || name.contains('MASADA') || name.contains('BT')) {
          targetDevice = d;
          break;
        }
      }
      targetDevice ??= devices.isNotEmpty ? devices.first : null;

      if (targetDevice != null) {
        _connection = await BluetoothConnection.toAddress(targetDevice.address);
        setState(() {
          _isConnected = true;
          _isConnecting = false;
        });

        _connection!.input!.listen(_processData, onDone: () {
          setState(() => _isConnected = false);
        });
      } else {
        setState(() => _isConnecting = false);
      }
    } catch (e) {
      setState(() => _isConnecting = false);
    }
  }

  // ... (데이터 처리 및 나머지 로직은 이전과 동일 유지) ...
  // UI 부분만 초대형 스케일로 수정함

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 10),
              Expanded(
                child: _isCampingMode ? _buildCampingDashboard() : _buildStandardDashboard(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 💡 UI 대형화 적용 (폰트 및 여백)
  Widget _buildStandardDashboard() {
    return Row(
      children: [
        Expanded(flex: 3, child: _buildLeftPanel()),
        const SizedBox(width: 20),
        Expanded(flex: 5, child: _buildCenterSocGauge()), // 비율 5로 확장
        const SizedBox(width: 20),
        Expanded(flex: 3, child: _buildRightPanel()),
      ],
    );
  }

  Widget _buildLeftPanel() {
    Color effColor = _getEfficiencyColor(_efficiencyScore);
    return Column(
      children: [
        Expanded(child: _buildBigCard("주행 효율 (3분)", "$_efficiencyScore", "점", effColor)),
        const SizedBox(height: 15),
        Expanded(child: _buildBigCard("주행가능거리", _bmsDistance.toStringAsFixed(1), "km", Colors.white)),
      ],
    );
  }

  // 💡 중앙 게이지 초대형화
  Widget _buildCenterSocGauge() {
    Color effColor = _getEfficiencyColor(_efficiencyScore);
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(20)),
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 280, height: 280, // 300px으로 확대
              child: CircularProgressIndicator(
                value: _soc / 100.0, strokeWidth: 24, // 두께 24px
                valueColor: AlwaysStoppedAnimation<Color>(effColor),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("${_recent3MinEfficiency.toStringAsFixed(1)} km/kWh", style: TextStyle(color: effColor, fontSize: 24, fontWeight: FontWeight.bold)),
                Text("${_soc.toStringAsFixed(1)}%", style: TextStyle(color: effColor, fontSize: 72, fontWeight: FontWeight.bold)), // 72pt
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBigCard(String title, String val, String unit, Color color) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(20)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: const TextStyle(fontSize: 18, color: Colors.white54)),
          const SizedBox(height: 10),
          Text(val, style: TextStyle(fontSize: 44, fontWeight: FontWeight.bold, color: color)),
          Text(unit, style: const TextStyle(fontSize: 20, color: Colors.white70)),
        ],
      ),
    );
  }

  // ... 나머지 UI도 동일한 비율로 확대 ...
}
