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
      title: 'MASADA VAN EV MONITOR',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D0F12),
      ),
      home: const DashboardScreen(),
    );
  }
}

class _DrivingSample {
  final double powerKw;
  final double estimatedSpeedKmh;
  _DrivingSample(this.powerKw, this.estimatedSpeedKmh);
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _isCampingMode = false;
  static const double _batteryTotalKwh = 38.7;

  // 블루투스 통신
  BluetoothConnection? _connection;
  bool _isConnected = false;
  bool _isConnecting = false;
  final List<int> _rxBuffer = [];
  Timer? _autoConnectTimer;
  Timer? _heartbeatTimer;

  // 실시간 전기차 데이터 (초기값 0.0)
  double _soc = 0.0;            
  double _voltage = 0.0;       
  double _current = 0.0;         
  double _powerKw = 0.0;         
  double _chargePowerKw = 0.0;   
  double _batteryTemp = 0.0;    
  int _soh = 0;                 
  double _bmsDistance = 0.0;   
  
  // 3분 전비 및 효율 점수
  final List<_DrivingSample> _recent3MinSamples = [];
  double _recent3MinEfficiency = 0.0;
  int _efficiencyScore = 0;
  
  // 누적 통계
  double _accumulatedRegenKwh = 0.0;
  double _driveEnergyKwh = 0.0;
  double _hvacEnergyKwh = 0.0;
  int _drivingSeconds = 0;
  Timer? _drivingTimer;

  @override
  void initState() {
    super.initState();
    _startDrivingTimer();
    _connectToLogger();
    // 10초 자동 재연결 유지
    _autoConnectTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (!_isConnected && !_isConnecting) {
        _connectToLogger();
      }
    });
  }

  @override
  void dispose() {
    _autoConnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _drivingTimer?.cancel();
    _connection?.dispose();
    super.dispose();
  }

  void _resetData() {
    if (mounted) {
      setState(() {
        _soc = 0.0;
        _voltage = 0.0;
        _current = 0.0;
        _powerKw = 0.0;
        _chargePowerKw = 0.0;
        _batteryTemp = 0.0;
        _soh = 0;
        _bmsDistance = 0.0;
        _recent3MinEfficiency = 0.0;
        _efficiencyScore = 0;
      });
    }
  }

  // 🔄 가장 안정적인 1초 하트비트
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_isConnected && _connection != null) {
        try {
          _connection!.output.add(Uint8List.fromList([0xAA, 0x55, 0x01, 0x00, 0x00, 0x00])); 
          _connection!.output.allSent;
        } catch (e) {
          debugPrint("Heartbeat 에러: $e");
        }
      }
    });
  }

  // 🔄 순정앱 충돌을 막고 무조건 접속하는 블루투스 엔진
  Future<void> _connectToLogger() async {
    if (_isConnected || _isConnecting) return;
    if (mounted) setState(() => _isConnecting = true);

    try {
      if (_connection != null) {
        await _connection!.close();
        _connection!.dispose();
        _connection = null;
        await Future.delayed(const Duration(milliseconds: 500));
      }

      List<BluetoothDevice> devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      BluetoothDevice? targetDevice;

      for (var d in devices) {
        String name = (d.name ?? '').toUpperCase();
        if (name.contains('EV') || name.contains('LOGGER') || name.contains('OBD') || name.contains('MASADA')) {
          targetDevice = d;
          break;
        }
      }
      if (targetDevice == null && devices.isNotEmpty) {
        targetDevice = devices.first;
      }

      if (targetDevice != null) {
        _connection = await BluetoothConnection.toAddress(targetDevice.address);
        
        _startHeartbeat(); // 연결 성공시 하트비트 가동

        if (mounted) {
          setState(() {
            _isConnected = true;
            _isConnecting = false;
          });
        }

        _connection!.input!.listen(
          (Uint8List data) {
            _processData(data);
          },
          onDone: () {
            _heartbeatTimer?.cancel();
            _resetData();
            if (mounted) setState(() { _isConnected = false; _isConnecting = false; });
          },
          onError: (error) {
            _heartbeatTimer?.cancel();
            _resetData();
            if (mounted) setState(() { _isConnected = false; _isConnecting = false; });
          },
          cancelOnError: false,
        );
      } else {
        if (mounted) setState(() => _isConnecting = false);
      }
    } catch (e) {
      if (mounted) setState(() { _isConnected = false; _isConnecting = false; });
    }
  }

  // 데이터 파싱 파트 (수정 없이 그대로)
  void _processData(Uint8List data) {
    _rxBuffer.addAll(data);

    while (_rxBuffer.length >= 12) {
      int headerIndex = -1;
      int packetType = 0;

      for (int i = 0; i < _rxBuffer.length - 1; i++) {
        if (_rxBuffer[i] == 0xAA && _rxBuffer[i + 1] == 0x55) {
          headerIndex = i; packetType = 1; break;
        } else if (_rxBuffer[i] == 0x7F && _rxBuffer[i + 1] == 0x7F) {
          headerIndex = i; packetType = 2; break;
        } else if (_rxBuffer[i] == 0x24 && _rxBuffer[i + 1] == 0x45) {
          headerIndex = i; packetType = 3; break;
        }
      }

      if (headerIndex == -1) {
        if (_rxBuffer.length > 1) _rxBuffer.removeRange(0, _rxBuffer.length - 1);
        break;
      }

      if (headerIndex > 0) _rxBuffer.removeRange(0, headerIndex);
      if (_rxBuffer.length < 14) break;

      _parseEvPacket(_rxBuffer.sublist(0, 14), packetType);
      _rxBuffer.removeRange(0, 14);
    }
  }

  void _parseEvPacket(List<int> p, int type) {
    try {
      double parsedSoc = _soc;
      double parsedVolt = _voltage;
      double parsedCurr = _current;
      double parsedTemp = _batteryTemp;
      int parsedSoh = _soh;

      if (type == 1) {
        int rawVolt = (p[2] << 8) | p[3];
        if (rawVolt > 500 && rawVolt < 5000) parsedVolt = rawVolt / 10.0;

        int rawCurr = (p[4] << 8) | p[5];
        if (rawCurr >= 0 && rawCurr <= 65535) {
          parsedCurr = (rawCurr - 32768) / 10.0;
          if (parsedCurr.abs() > 400) parsedCurr = (rawCurr - 30000) / 10.0;
        }

        int rawSoc = p[6];
        if (rawSoc > 0 && rawSoc <= 100) {
          parsedSoc = rawSoc.toDouble();
        } else if (p.length > 9 && p[9] > 0 && p[9] <= 100) {
          parsedSoc = p[9].toDouble();
        }

        int rawTemp = p[7] - 40;
        if (rawTemp >= -40 && rawTemp <= 120) parsedTemp = rawTemp.toDouble();
        if (p[8] >= 50 && p[8] <= 100) parsedSoh = p[8];

      } else if (type == 2 || type == 3) {
        int rawSoc = p[2];
        if (rawSoc > 0 && rawSoc <= 100) parsedSoc = rawSoc.toDouble();

        int rawVolt = (p[3] << 8) | p[4];
        if (rawVolt > 1000 && rawVolt < 5000) parsedVolt = rawVolt / 10.0;

        int rawCurr = (p[5] << 8) | p[6];
        parsedCurr = (rawCurr - 32768) / 10.0;

        int rawTemp = p[7] - 40;
        if (rawTemp >= -30 && rawTemp <= 100) parsedTemp = rawTemp.toDouble();
        if (p[8] >= 50 && p[8] <= 100) parsedSoh = p[8];
      }

      _soc = parsedSoc;
      _voltage = parsedVolt;
      _current = parsedCurr;
      _batteryTemp = parsedTemp;
      _soh = parsedSoh == 0 ? 94 : parsedSoh;

      double calcPower = (_voltage * _current) / 1000.0;
      _powerKw = calcPower;
      if (_current < 0) _chargePowerKw = calcPower.abs(); else _chargePowerKw = 0.0;

      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _startDrivingTimer() {
    _drivingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _drivingSeconds++;
          if (!_isCampingMode && _isConnected) {
            if (_current < -0.5 && _chargePowerKw > 0.1) _accumulatedRegenKwh += (_chargePowerKw / 3600.0);
            if (_powerKw > 1.0) _driveEnergyKwh += (_powerKw / 3600.0);
            else if (_powerKw > 0.05) _hvacEnergyKwh += (_powerKw / 3600.0);
            _update3MinEfficiency();
          }
        });
      }
    });
  }

  void _update3MinEfficiency() {
    double speed = 0.0;
    if (_powerKw > 1.0) speed = (_powerKw * 4.5).clamp(10.0, 100.0);

    _recent3MinSamples.add(_DrivingSample(_powerKw, speed));
    if (_recent3MinSamples.length > 180) _recent3MinSamples.removeAt(0);

    if (_recent3MinSamples.length >= 10) {
      double totalNetKwh = 0.0;
      double totalDistanceKm = 0.0;
      for (var s in _recent3MinSamples) {
        totalNetKwh += (s.powerKw / 3600.0);
        totalDistanceKm += (s.estimatedSpeedKmh / 3600.0);
      }
      if (totalNetKwh > 0.005 && totalDistanceKm > 0.01) {
        double calcEff = totalDistanceKm / totalNetKwh;
        _recent3MinEfficiency = calcEff.clamp(2.0, 10.0);
      }
    }
    double rawScore = ((_recent3MinEfficiency - 3.7) / (7.7 - 3.7)) * 100.0;
    _efficiencyScore = rawScore.clamp(0.0, 100.0).round();

    double currentRemainKwh = (_batteryTotalKwh * (_soh / 100.0)) * (_soc / 100.0);
    _bmsDistance = double.parse((currentRemainKwh * _recent3MinEfficiency).toStringAsFixed(1));
  }

  Color _getEfficiencyColor(int score) {
    if (score >= 80) return const Color(0xFF00E676);
    if (score >= 60) return const Color(0xFF00E5FF);
    if (score >= 40) return const Color(0xFFFFD600);
    if (score >= 20) return const Color(0xFFFF9100);
    return const Color(0xFFFF5252);
  }

  String _formatDrivingTime(int seconds) {
    int h = seconds ~/ 3600;
    int m = (seconds % 3600) ~/ 60;
    int s = seconds % 60;
    return "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  double _getSafePowerLimitKw(double temp) {
    if (temp < 0) return 15.0;
    if (temp < 10) return 25.0;
    if (temp < 20) return 40.0;
    return 50.0;
  }

  Color _getPowerGaugeColor(double powerKw, double temp) {
    if (powerKw < 0) return const Color(0xFFFF9100);
    double limit = _getSafePowerLimitKw(temp);
    if (powerKw > limit) return const Color(0xFFFF5252);
    else if (powerKw > limit * 0.75) return const Color(0xFFFFB300);
    return const Color(0xFF00E676);
  }

  Map<String, dynamic> _getBatteryTempGrade() {
    double t = _batteryTemp;
    if (t >= 15.0 && t <= 45.0) return {'grade': 'S', 'amp': '120A', 'color': const Color(0xFF00E676), 'desc': '최적 풀파워'};
    else if (t >= 10.0 && t < 15.0) return {'grade': 'A(저온)', 'amp': '63A', 'color': const Color(0xFF00E5FF), 'desc': '저온 감발'};
    else if (t > 45.0 && t <= 48.0) return {'grade': 'A(고온)', 'amp': '63A', 'color': const Color(0xFFFFD600), 'desc': '고온 진입'};
    else if (t > 48.0 && t <= 54.0) return {'grade': 'B', 'amp': '42A', 'color': const Color(0xFFFF9100), 'desc': '고온 감발'};
    else if (t >= 0.0 && t < 10.0) return {'grade': 'C', 'amp': '25A', 'color': const Color(0xFF2979FF), 'desc': '극저온'};
    else return {'grade': 'D', 'amp': '13A', 'color': const Color(0xFFFF5252), 'desc': '초저속/제한'};
  }

  String _calculateChargeTimeToFull() {
    if (_chargePowerKw < 0.2) return "--";
    double currentSoc = _soc;
    if (currentSoc >= 100.0) return "충전 완료";

    double totalHours = 0.0;
    bool isFastCharge = _chargePowerKw > 10.0;

    if (!isFastCharge) {
      double remainKwh = _batteryTotalKwh * (100.0 - currentSoc) / 100.0;
      totalHours = remainKwh / _chargePowerKw;
    } else {
      if (currentSoc < 80.0) {
        double kwh80 = _batteryTotalKwh * (80.0 - currentSoc) / 100.0;
        totalHours += kwh80 / _chargePowerKw;
        currentSoc = 80.0;
      }
      if (currentSoc < 90.0) {
        double kwh90 = _batteryTotalKwh * (90.0 - currentSoc) / 100.0;
        double power80to90 = _chargePowerKw * 0.60;
        totalHours += kwh90 / (power80to90 < 7.0 ? 7.0 : power80to90);
        currentSoc = 90.0;
      }
      if (currentSoc < 100.0) {
        double kwh100 = _batteryTotalKwh * (100.0 - currentSoc) / 100.0;
        double power90to100 = _chargePowerKw * 0.25;
        totalHours += kwh100 / (power90to100 < 3.5 ? 3.5 : power90to100);
      }
    }
    int totalMinutes = (totalHours * 60).round();
    int h = totalMinutes ~/ 60;
    int m = totalMinutes % 60;
    return h > 0 ? "$h시간 $m분 남음" : "$m분 남음";
  }

  String _calculateChargeRatePerHour() {
    if (_chargePowerKw < 0.2) return "(0.0 %/h)";
    double rate = (_chargePowerKw / _batteryTotalKwh) * 100.0;
    return "(+${rate.toStringAsFixed(1)} %/h)";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 6.0),
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 6),
              Expanded(child: _buildStandardDashboard()),
              const SizedBox(height: 6),
              _buildPowerBar(),
              const SizedBox(height: 6),
              _buildBottomStatusBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          "MASADA VAN  EV MONITOR",
          style: TextStyle(color: Color(0xFF00E676), fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF00E676).withOpacity(0.5))),
              child: const Row(
                children: [
                  Icon(Icons.circle, color: Color(0xFF00E676), size: 10),
                  SizedBox(width: 6),
                  Text("오리지널 네온", style: TextStyle(color: Color(0xFF00E676), fontSize: 14)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _connectToLogger,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E242C),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _isConnected ? const Color(0xFF00E676) : Colors.redAccent),
                ),
                child: Row(
                  children: [
                    Icon(Icons.circle, color: _isConnected ? const Color(0xFF00E676) : Colors.redAccent, size: 10),
                    const SizedBox(width: 6),
                    Text(
                      _isConnected ? "EvLogger 연결됨" : (_isConnecting ? "연결 시도 중..." : "수동 연결"),
                      style: TextStyle(color: _isConnected ? const Color(0xFF00E676) : Colors.redAccent, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // 💡 메인 3분할 비율 (25 : 50 : 25) - 중앙을 훨씬 거대하게
  Widget _buildStandardDashboard() {
    return Row(
      children: [
        Expanded(flex: 25, child: _buildLeftPanel()),
        const SizedBox(width: 12),
        Expanded(flex: 50, child: _buildCenterSocGauge()),
        const SizedBox(width: 12),
        Expanded(flex: 25, child: _buildRightPanel()),
      ],
    );
  }

  // 💡 좌측 패널 (텍스트 스케일업)
  Widget _buildLeftPanel() {
    Color effThemeColor = _getEfficiencyColor(_efficiencyScore);
    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF222A35))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("실시간 주행 효율 (3분)", style: TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w500)),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text("$_efficiencyScore", style: TextStyle(color: effThemeColor, fontSize: 52, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 6),
                    const Text("점", style: TextStyle(color: Colors.white54, fontSize: 24, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _buildCard(
            title: "BMS 주행가능거리 (3분 전비)",
            valueText: _bmsDistance.toStringAsFixed(1),
            unitText: "km",
            valueColor: effThemeColor,
          ),
        ),
      ],
    );
  }

  // 💡 중앙 게이지 극대화 (350px x 350px, 두께 26px, 폰트 80pt)
  Widget _buildCenterSocGauge() {
    Color effThemeColor = _getEfficiencyColor(_efficiencyScore);
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF222A35))),
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 350,
              height: 350,
              child: CircularProgressIndicator(
                value: (_soc / 100.0).clamp(0.0, 1.0),
                strokeWidth: 26,
                backgroundColor: const Color(0xFF222A35),
                valueColor: AlwaysStoppedAnimation<Color>(effThemeColor),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(_recent3MinEfficiency.toStringAsFixed(1), style: TextStyle(color: effThemeColor, fontSize: 36, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 6),
                    Text("km/kWh", style: TextStyle(color: effThemeColor.withOpacity(0.85), fontSize: 22, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(_soc.toStringAsFixed(1), style: TextStyle(color: effThemeColor, fontSize: 80, fontWeight: FontWeight.bold)),
                    Text("%", style: TextStyle(color: effThemeColor, fontSize: 34, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 💡 우측 패널 (회생 +% 이득 부분 훨씬 크게 + 점유율 Bar 추가)
  Widget _buildRightPanel() {
    bool isChargingOrRegen = _chargePowerKw > 0.1;
    bool isFastCharge = _chargePowerKw > 10.0;
    String cardTitle = isChargingOrRegen ? (isFastCharge ? "⚡ 급속 충전 중" : "🔌 완속 충전 중") : "실시간 충전량";
    if (isChargingOrRegen && _current >= -5.0 && _chargePowerKw <= 1.0) cardTitle = "♻️ 회생제동 충전 중";
    Color titleColor = isChargingOrRegen ? const Color(0xFFFFB300) : Colors.white70;

    double totalConsumed = _driveEnergyKwh + _hvacEnergyKwh;
    int drivePct = totalConsumed > 0.01 ? ((_driveEnergyKwh / totalConsumed) * 100).round() : 85;
    int hvacPct = 100 - drivePct;

    double regenKw = _current < 0 ? _chargePowerKw : 0.0;
    double regenPct = (_accumulatedRegenKwh / _batteryTotalKwh) * 100.0;
    double gainedKm = _accumulatedRegenKwh * _recent3MinEfficiency;

    return Column(
      children: [
        // 상단 충전량 카드
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF13171D),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isChargingOrRegen ? const Color(0xFFFFB300).withOpacity(0.6) : const Color(0xFF222A35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(cardTitle, style: TextStyle(color: titleColor, fontSize: 18, fontWeight: FontWeight.bold)),
                    Text(_calculateChargeRatePerHour(), style: TextStyle(color: isChargingOrRegen ? const Color(0xFFFFB300) : Colors.white38, fontSize: 16)),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(_chargePowerKw.toStringAsFixed(1), style: TextStyle(color: isChargingOrRegen ? const Color(0xFFFFB300) : Colors.white38, fontSize: 52, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 6),
                    const Text("kW", style: TextStyle(color: Colors.white54, fontSize: 24, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 💡 하단 회생/비율 카드 집중 강화 (바 추가 및 텍스트 거대화)
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF13171D),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: regenKw > 0.5 ? const Color(0xFFFF9100).withOpacity(0.6) : const Color(0xFF222A35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 1. 회생 이득 텍스트 대폭 확대
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("회생 ${regenKw.toStringAsFixed(1)}kW", style: TextStyle(color: regenKw > 0.1 ? const Color(0xFFFF9100) : Colors.white54, fontSize: 20, fontWeight: FontWeight.bold)),
                    Text("+${regenPct.toStringAsFixed(1)}%", style: const TextStyle(color: Color(0xFF00E676), fontSize: 20, fontWeight: FontWeight.bold)),
                    Text("+${gainedKm.toStringAsFixed(1)}km 이득", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 20, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 12),
                // 2. 주행 / 공조 텍스트
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    const Text("주행 ", style: TextStyle(color: Colors.white70, fontSize: 18)),
                    Text("$drivePct%", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 36, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 14),
                    const Text("· 공조 ", style: TextStyle(color: Colors.white70, fontSize: 18)),
                    Text("$hvacPct%", style: const TextStyle(color: Color(0xFFFFB300), fontSize: 36, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                // 3. 💡 주행/공조 점유율 Bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: drivePct / 100.0,
                    backgroundColor: const Color(0xFFFFB300), // 공조색(오렌지)
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)), // 주행색(시안)
                    minHeight: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // 좌측 패널 전용 빌더
  Widget _buildCard({required String title, required String valueText, required String unitText, required Color valueColor}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF222A35))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(valueText, style: TextStyle(color: valueColor, fontSize: 52, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Text(unitText, style: const TextStyle(color: Colors.white54, fontSize: 24, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPowerBar() {
    double normalized = ((_powerKw + 50) / 100).clamp(0.0, 1.0);
    double safeLimitKw = _getSafePowerLimitKw(_batteryTemp);
    double limitNormalized = ((safeLimitKw + 50) / 100).clamp(0.0, 1.0);
    Color dynamicBarColor = _getPowerGaugeColor(_powerKw, _batteryTemp);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF222A35))),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("◀ 회생제동 (REGEN)", style: TextStyle(color: Color(0xFFFF9100), fontSize: 14, fontWeight: FontWeight.bold)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("실시간: ${_powerKw.toStringAsFixed(1)} kW", style: TextStyle(color: dynamicBarColor, fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Text("(한계: ${safeLimitKw.toStringAsFixed(0)}kW)", style: const TextStyle(color: Colors.white38, fontSize: 14)),
                ],
              ),
              const Text("가속 출력 (POWER) ▶", style: TextStyle(color: Colors.redAccent, fontSize: 14, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              double barWidth = constraints.maxWidth;
              double pinLeft = (barWidth * limitNormalized) - 4.0;
              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  LinearProgressIndicator(value: normalized, backgroundColor: const Color(0xFF222A35), valueColor: AlwaysStoppedAnimation<Color>(dynamicBarColor), minHeight: 14),
                  Positioned(left: (barWidth * 0.5) - 1.0, child: Container(width: 2.0, height: 18, color: Colors.white54)),
                  Positioned(
                    left: pinLeft.clamp(0.0, barWidth - 8.0),
                    child: Container(width: 8, height: 20, decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(2.0), boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 3, offset: Offset(0, 1))])),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBottomStatusBar() {
    Map<String, dynamic> tempGrade = _getBatteryTempGrade();
    double totalConsumedKwh = _driveEnergyKwh + _hvacEnergyKwh;
    double consumedPct = (_batteryTotalKwh > 0) ? (totalConsumedKwh / _batteryTotalKwh) * 100.0 : 0.0;
    double liveConsumeWatts = _current > 0 ? (_voltage * _current) : 0.0;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildBottomCard(title: "운행 시간", child: Text(_formatDrivingTime(_drivingSeconds), style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 18, fontWeight: FontWeight.bold))),
        _buildBottomCard(
          title: "이번 운행 소모량",
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("${totalConsumedKwh.toStringAsFixed(1)} kWh", style: const TextStyle(color: Color(0xFFFFB300), fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Text("(-${consumedPct.toStringAsFixed(1)}%)", style: const TextStyle(color: Color(0xFFFF5252), fontSize: 14, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        _buildBottomCard(title: "실시간 소모 전력", child: Text("${liveConsumeWatts.toStringAsFixed(0)} W", style: TextStyle(color: liveConsumeWatts > 1000 ? const Color(0xFFFFB300) : Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
        _buildBottomCard(title: "배터리 건강(SOH)", child: Text("$_soh %", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 18, fontWeight: FontWeight.bold))),
        _buildBottomCard(
          title: "배터리온도 & 급속허용",
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("${_batteryTemp.toStringAsFixed(1)}°C", style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: (tempGrade['color'] as Color).withOpacity(0.2), borderRadius: BorderRadius.circular(4), border: Border.all(color: tempGrade['color'] as Color, width: 0.8)),
                    child: Text("${tempGrade['grade']} (${tempGrade['amp']})", style: TextStyle(color: tempGrade['color'] as Color, fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(width: 100, height: 6, decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), gradient: const LinearGradient(colors: [Color(0xFF2979FF), Color(0xFF00E5FF), Color(0xFF00E676), Color(0xFFFFD600), Color(0xFFFF9100), Color(0xFFFF5252)]))),
                  Positioned(
                    left: (((_batteryTemp + 10) / 70.0).clamp(0.0, 1.0) * 92),
                    child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black, blurRadius: 2)])),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBottomCard({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFF222A35))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}
