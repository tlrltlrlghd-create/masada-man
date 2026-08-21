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

  // 실시간 전기차 데이터
  double _soc = 87.0;            // 배터리 잔량 (%)
  double _voltage = 318.0;       // 배터리 전압 (V)
  double _current = 1.0;         // 전류 (A)
  double _powerKw = 0.3;         // 실시간 파워 (kW)
  double _chargePowerKw = 0.0;   // 충전/회생 파워 (kW)
  double _batteryTemp = 30.0;    // 배터리 온도 (°C)
  int _soh = 94;                 // SOH (%)
  double _bmsDistance = 185.2;   // BMS 주행거리 (km)
  double _efficiencyDist = 200.1;// 연비 주행거리 (km)
  
  // 누적 회생제동 회수량
  double _accumulatedRegenKwh = 0.0;

  // 운행 시간 타이머
  int _drivingSeconds = 0;
  Timer? _drivingTimer;

  @override
  void initState() {
    super.initState();
    _startDrivingTimer();
    _connectToLogger();
    _autoConnectTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (!_isConnected && !_isConnecting) {
        _connectToLogger();
      }
    });
  }

  @override
  void dispose() {
    _autoConnectTimer?.cancel();
    _drivingTimer?.cancel();
    _connection?.dispose();
    super.dispose();
  }

  void _startDrivingTimer() {
    _drivingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _drivingSeconds++;
          // 회생제동 중일 때 1초 단위 적분 누적 (주행 중 회생전력: kW * (1/3600)h)
          if (_current < -0.5 && _chargePowerKw > 0.1 && !_isCampingMode) {
            _accumulatedRegenKwh += (_chargePowerKw / 3600.0);
          }
        });
      }
    });
  }

  String _formatDrivingTime(int seconds) {
    int h = seconds ~/ 3600;
    int m = (seconds % 3600) ~/ 60;
    int s = seconds % 60;
    return "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  // ==========================================
  // 🌡️ 배터리 온도별 안전 가속 한계치(kW) 및 색상 결정
  // ==========================================
  double _getSafePowerLimitKw(double temp) {
    if (temp < 0) return 15.0;       // 영하: 15kW 제한
    if (temp < 10) return 25.0;      // 0~10도: 25kW 제한
    if (temp < 20) return 40.0;      // 10~20도: 40kW 제한
    return 50.0;                     // 20도 이상: 50kW 정상 풀파워
  }

  Color _getPowerGaugeColor(double powerKw, double temp) {
    if (powerKw < 0) {
      return const Color(0xFFFF9100); // 회생제동 (앰버 오렌지)
    }
    double limit = _getSafePowerLimitKw(temp);
    if (powerKw > limit) {
      return const Color(0xFFFF5252); // 과가속 경고 (빨강)
    } else if (powerKw > limit * 0.75) {
      return const Color(0xFFFFB300); // 주의 구간 (주황/옐로우)
    }
    return const Color(0xFF00E676);   // 정상 안전 주행 (네온 그린)
  }

  // ==========================================
  // 🌡️ 마사다 배터리 온도별 급속충전 등급 및 컬러 평가
  // ==========================================
  Map<String, dynamic> _getBatteryTempGrade() {
    double t = _batteryTemp;
    
    if (t >= 15.0 && t <= 45.0) {
      return {'grade': 'S', 'amp': '120A', 'color': const Color(0xFF00E676), 'desc': '최적 풀파워'};
    } else if (t >= 10.0 && t < 15.0) {
      return {'grade': 'A(저온)', 'amp': '63A', 'color': const Color(0xFF00E5FF), 'desc': '저온 감발'};
    } else if (t > 45.0 && t <= 48.0) {
      return {'grade': 'A(고온)', 'amp': '63A', 'color': const Color(0xFFFFD600), 'desc': '고온 진입'};
    } else if (t > 48.0 && t <= 54.0) {
      return {'grade': 'B', 'amp': '42A', 'color': const Color(0xFFFF9100), 'desc': '고온 감발'};
    } else if (t >= 0.0 && t < 10.0) {
      return {'grade': 'C', 'amp': '25A', 'color': const Color(0xFF2979FF), 'desc': '극저온'};
    } else {
      return {'grade': 'D', 'amp': '13A', 'color': const Color(0xFFFF5252), 'desc': '초저속/제한'};
    }
  }

  // 충전 테이퍼링 잔여시간 계산
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

  String _calculateCampingRemainingTime(double targetSoc) {
    double consumeKw = _powerKw.abs();
    if (consumeKw < 0.05) return "소모 없음 (대기 중)";

    double currentKwh = _batteryTotalKwh * (_soc / 100.0);
    double targetKwh = _batteryTotalKwh * (targetSoc / 100.0);
    double availableKwh = currentKwh - targetKwh;

    if (availableKwh <= 0) return "도달 완료";

    double hours = availableKwh / consumeKw;
    if (hours > 99) return "99시간 이상";

    int totalMinutes = (hours * 60).round();
    int h = totalMinutes ~/ 60;
    int m = totalMinutes % 60;
    return "$h시간 $m분";
  }

  Future<void> _connectToLogger() async {
    if (_isConnected || _isConnecting) return;

    setState(() {
      _isConnecting = true;
    });

    try {
      List<BluetoothDevice> devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      BluetoothDevice? targetDevice;

      for (var d in devices) {
        String name = (d.name ?? '').toUpperCase();
        if (name.contains('EV') || name.contains('LOGGER') || name.contains('OBD') || name.contains('MASADA')) {
          targetDevice = d;
          break;
        }
      }

      targetDevice ??= devices.isNotEmpty ? devices.first : null;

      if (targetDevice != null) {
        _connection = await BluetoothConnection.toAddress(targetDevice.address);
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
            if (mounted) {
              setState(() {
                _isConnected = false;
                _isConnecting = false;
              });
            }
          },
          onError: (error) {
            debugPrint("[BLE Error] $error");
          },
          cancelOnError: false,
        );
      } else {
        if (mounted) setState(() => _isConnecting = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnected = false;
          _isConnecting = false;
        });
      }
    }
  }

  void _processData(Uint8List data) {
    _rxBuffer.addAll(data);

    while (_rxBuffer.length >= 8) {
      int headerIndex = -1;
      for (int i = 0; i < _rxBuffer.length - 1; i++) {
        if ((_rxBuffer[i] == 0xAA && _rxBuffer[i + 1] == 0x55) ||
            (_rxBuffer[i] == 0x7F && _rxBuffer[i + 1] == 0x7F) ||
            (_rxBuffer[i] == 0x24 && _rxBuffer[i + 1] == 0x45)) {
          headerIndex = i;
          break;
        }
      }

      if (headerIndex == -1) {
        if (_rxBuffer.length > 1) {
          _rxBuffer.removeRange(0, _rxBuffer.length - 1);
        }
        break;
      }

      if (headerIndex > 0) {
        _rxBuffer.removeRange(0, headerIndex);
      }

      if (_rxBuffer.length < 16) break;

      _parseEvPacket(_rxBuffer.sublist(0, 16));
      _rxBuffer.removeRange(0, 16);
    }
  }

  void _parseEvPacket(List<int> packet) {
    try {
      if (packet.length > 2 && packet[2] > 0 && packet[2] <= 100) {
        _soc = packet[2].toDouble();
      }

      if (packet.length > 4) {
        int rawVolt = (packet[3] << 8) | packet[4];
        if (rawVolt > 1000 && rawVolt < 5000) {
          _voltage = rawVolt / 10.0;
        }
      }

      if (packet.length > 6) {
        int rawCurr = (packet[5] << 8) | packet[6];
        double parsedCurr = (rawCurr - 32768) / 10.0;
        if (parsedCurr.abs() < 500) {
          _current = parsedCurr;
        }
      }

      if (packet.length > 7) {
        int rawTemp = packet[7] - 40;
        if (rawTemp >= -30 && rawTemp <= 100) {
          _batteryTemp = rawTemp.toDouble();
        }
      }

      if (packet.length > 8 && packet[8] > 50 && packet[8] <= 100) {
        _soh = packet[8];
      } else if (_soh == 0) {
        _soh = 94;
      }

      double calcPower = (_voltage * _current) / 1000.0;
      _powerKw = calcPower;

      if (_current < 0) {
        _chargePowerKw = calcPower.abs();
      } else {
        _chargePowerKw = 0.0;
      }

      _efficiencyDist = double.parse((_soc * 2.3).toStringAsFixed(1));
      _bmsDistance = double.parse((_soc * 2.13).toStringAsFixed(1));

      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 10),
              Expanded(
                child: _isCampingMode ? _buildCampingDashboard() : _buildStandardDashboard(),
              ),
              const SizedBox(height: 8),
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
        Text(
          _isCampingMode ? "MASADA VAN  CAMPING MODE" : "MASADA VAN  EV MONITOR",
          style: TextStyle(
            color: _isCampingMode ? const Color(0xFFFFB300) : const Color(0xFF00E676),
            fontSize: 16,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        Row(
          children: [
            GestureDetector(
              onTap: () {
                setState(() {
                  _isCampingMode = !_isCampingMode;
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _isCampingMode ? const Color(0xFFFFB300).withOpacity(0.2) : const Color(0xFF1E242C),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _isCampingMode ? const Color(0xFFFFB300) : Colors.white30,
                    width: 1.2,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isCampingMode ? Icons.bedtime : Icons.night_shelter_outlined,
                      color: _isCampingMode ? const Color(0xFFFFB300) : Colors.white70,
                      size: 13,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      "캠핑 모드",
                      style: TextStyle(
                        color: _isCampingMode ? const Color(0xFFFFB300) : Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1E242C),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF00E676).withOpacity(0.5)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.circle, color: Color(0xFF00E676), size: 8),
                  SizedBox(width: 4),
                  Text("오리지널 네온", style: TextStyle(color: Color(0xFF00E676), fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _connectToLogger,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E242C),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _isConnected ? const Color(0xFF00E676) : Colors.redAccent,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.circle,
                      color: _isConnected ? const Color(0xFF00E676) : Colors.redAccent,
                      size: 8,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isConnected ? "EvLogger 연결됨" : (_isConnecting ? "연결 시도 중..." : "수동 연결"),
                      style: TextStyle(
                        color: _isConnected ? const Color(0xFF00E676) : Colors.redAccent,
                        fontSize: 11,
                      ),
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

  Widget _buildStandardDashboard() {
    return Row(
      children: [
        Expanded(flex: 3, child: _buildLeftPanel()),
        const SizedBox(width: 14),
        Expanded(flex: 4, child: _buildCenterSocGauge()),
        const SizedBox(width: 14),
        Expanded(flex: 3, child: _buildRightPanel()),
      ],
    );
  }

  Widget _buildCampingDashboard() {
    double consumeWatts = (_voltage * _current).abs();
    double percentPerHour = consumeWatts > 0 ? (consumeWatts / (_batteryTotalKwh * 1000)) * 100 : 0.0;

    return Row(
      children: [
        Expanded(
          flex: 4,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF13171D),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFFFB300).withOpacity(0.4)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("현재 배터리 잔량", style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 4),
                Text(
                  "${_soc.toStringAsFixed(1)} %",
                  style: const TextStyle(color: Color(0xFF00E676), fontSize: 40, fontWeight: FontWeight.bold),
                ),
                const Divider(color: Colors.white12, height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Column(
                      children: [
                        const Text("실시간 소모 전력", style: TextStyle(color: Colors.white54, fontSize: 11)),
                        const SizedBox(height: 2),
                        Text(
                          "${consumeWatts.toStringAsFixed(0)} W",
                          style: const TextStyle(color: Color(0xFFFFB300), fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    Column(
                      children: [
                        const Text("시간당 소모율", style: TextStyle(color: Colors.white54, fontSize: 11)),
                        const SizedBox(height: 2),
                        Text(
                          "${percentPerHour.toStringAsFixed(1)} %/h",
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          flex: 6,
          child: Column(
            children: [
              Expanded(
                child: _buildCampingTimeCard(
                  title: "🛡️ 복귀 마진 (배터리 20% 도달까지)",
                  remainingTime: _calculateCampingRemainingTime(20.0),
                  subInfo: "남은 사용 가능량: ${((_soc - 20).clamp(0, 100) * _batteryTotalKwh / 100).toStringAsFixed(1)} kWh",
                  accentColor: const Color(0xFF00E5FF),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _buildCampingTimeCard(
                  title: "⚠️ 한계 마진 (배터리 0% 완전 방전까지)",
                  remainingTime: _calculateCampingRemainingTime(0.0),
                  subInfo: "총 잔여 전력량: ${(_soc * _batteryTotalKwh / 100).toStringAsFixed(1)} kWh",
                  accentColor: const Color(0xFFFF5252),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCampingTimeCard({
    required String title,
    required String remainingTime,
    required String subInfo,
    required Color accentColor,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF13171D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF222A35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500)),
              Text(subInfo, style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            remainingTime,
            style: TextStyle(color: accentColor, fontSize: 26, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftPanel() {
    return Column(
      children: [
        Expanded(
          child: _buildCard(
            title: "연비 주행거리 (2.3km/%)",
            valueText: _efficiencyDist.toStringAsFixed(1),
            unitText: "km",
            valueColor: const Color(0xFF00E676),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _buildCard(
            title: "BMS 주행가능거리",
            valueText: _bmsDistance.toStringAsFixed(1),
            unitText: "km",
            valueColor: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildCenterSocGauge() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF13171D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF222A35)),
      ),
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 170,
              height: 170,
              child: CircularProgressIndicator(
                value: _soc / 100.0,
                strokeWidth: 14,
                backgroundColor: const Color(0xFF222A35),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E676)),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("BATTERY", style: TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 1.5)),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      _soc.toStringAsFixed(1),
                      style: const TextStyle(color: Color(0xFF00E676), fontSize: 34, fontWeight: FontWeight.bold),
                    ),
                    const Text("%", style: TextStyle(color: Color(0xFF00E676), fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRightPanel() {
    bool isChargingOrRegen = _chargePowerKw > 0.1;
    bool isFastCharge = _chargePowerKw > 10.0;
    
    String cardTitle = "실시간 충전량";
    Color titleColor = Colors.white70;
    String subRate = _calculateChargeRatePerHour();
    String? bottomNotice;

    if (isChargingOrRegen) {
      if (_current < -5.0 && _chargePowerKw > 1.0) {
        cardTitle = isFastCharge ? "⚡ 급속 충전 중" : "🔌 완속 충전 중";
        titleColor = const Color(0xFFFFB300);
        bottomNotice = "완충까지: ${_calculateChargeTimeToFull()}";
      } else {
        cardTitle = "♻️ 회생제동 충전 중";
        titleColor = const Color(0xFFFF9100);
      }
    }

    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF13171D),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isChargingOrRegen ? const Color(0xFFFFB300).withOpacity(0.6) : const Color(0xFF222A35),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(cardTitle, style: TextStyle(color: titleColor, fontSize: 11, fontWeight: FontWeight.bold)),
                    Text(subRate, style: TextStyle(color: isChargingOrRegen ? const Color(0xFFFFB300) : Colors.white38, fontSize: 10)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      _chargePowerKw.toStringAsFixed(1),
                      style: TextStyle(
                        color: isChargingOrRegen ? const Color(0xFFFFB300) : Colors.white38,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Text("kW", style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
                if (bottomNotice != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    bottomNotice,
                    style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _buildCard(
            title: "실시간 배터리 전력",
            valueText: "${(_voltage * _current).abs().toStringAsFixed(0)}",
            unitText: "W",
            valueColor: Colors.white,
            subText: "${_voltage.toStringAsFixed(0)}V / ${_current.abs().toStringAsFixed(1)}A",
          ),
        ),
      ],
    );
  }

  Widget _buildCard({
    required String title,
    required String valueText,
    required String unitText,
    required Color valueColor,
    String? subText,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF13171D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF222A35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: const TextStyle(color: Colors.white70, fontSize: 11)),
              if (subText != null)
                Text(subText, style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(valueText, style: TextStyle(color: valueColor, fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(width: 4),
              Text(unitText, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  // ==========================================
  // ⚡ 배터리 온도별 동적 한계선(눈금) & 가속 색상 반영 파워바
  // ==========================================
  Widget _buildPowerBar() {
    double normalized = ((_powerKw + 50) / 100).clamp(0.0, 1.0);
    double safeLimitKw = _getSafePowerLimitKw(_batteryTemp);
    // 한계 눈금 위치 (-50kW ~ +50kW 범위에서 임계값의 비율)
    double limitNormalized = ((safeLimitKw + 50) / 100).clamp(0.0, 1.0);
    Color dynamicBarColor = _getPowerGaugeColor(_powerKw, _batteryTemp);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF13171D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF222A35)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("◀ 회생제동 (REGEN)", style: TextStyle(color: Color(0xFFFF9100), fontSize: 10)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "실시간: ${_powerKw.toStringAsFixed(1)} kW",
                    style: TextStyle(color: dynamicBarColor, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "(한계: ${safeLimitKw.toStringAsFixed(0)}kW)",
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                ],
              ),
              const Text("가속 출력 (POWER) ▶", style: TextStyle(color: Colors.redAccent, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 4),
          // 파워 게이지 바 + 온도별 동적 한계선 인디케이터
          LayoutBuilder(
            builder: (context, constraints) {
              double barWidth = constraints.maxWidth;
              double pinLeft = (barWidth * limitNormalized) - 3.0; // 핀 너비의 절반 보정

              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  // 실시간 파워 게이지 바
                  LinearProgressIndicator(
                    value: normalized,
                    backgroundColor: const Color(0xFF222A35),
                    valueColor: AlwaysStoppedAnimation<Color>(dynamicBarColor),
                    minHeight: 6,
                  ),
                  // 중앙 0kW 기준선 눈금
                  Positioned(
                    left: (barWidth * 0.5) - 0.5,
                    child: Container(
                      width: 1.5,
                      height: 8,
                      color: Colors.white30,
                    ),
                  ),
                  // 📍 배터리 온도별 동적 안전 한계선 눈금 (붉은색 핀)
                  Positioned(
                    left: pinLeft.clamp(0.0, barWidth - 6.0),
                    child: Container(
                      width: 6,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(1.5),
                        boxShadow: const [
                          BoxShadow(color: Colors.black54, blurRadius: 2, offset: Offset(0, 1)),
                        ],
                      ),
                    ),
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
    double regenPct = (_accumulatedRegenKwh / _batteryTotalKwh) * 100.0;
    Map<String, dynamic> tempGrade = _getBatteryTempGrade();

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // 1. 운행 시간
        _buildBottomCard(
          title: "운행 시간",
          child: Text(
            _formatDrivingTime(_drivingSeconds),
            style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
        // 2. 회생제동 누적 회수량
        _buildBottomCard(
          title: "회생 회수량 (REGEN)",
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "${_accumulatedRegenKwh.toStringAsFixed(2)} kWh",
                style: const TextStyle(color: Color(0xFFFF9100), fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 4),
              Text(
                "(+${regenPct.toStringAsFixed(1)}%)",
                style: const TextStyle(color: Color(0xFF00E676), fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        // 3. 배터리 건강도
        _buildBottomCard(
          title: "배터리 건강(SOH)",
          child: Text(
            "$_soh %",
            style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ),
        // 4. 배터리 온도 & 저온/고온 분리 급속 등급
        _buildBottomCard(
          title: "배터리온도 & 급속허용",
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "${_batteryTemp.toStringAsFixed(1)}°C",
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: (tempGrade['color'] as Color).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: tempGrade['color'] as Color, width: 0.8),
                    ),
                    child: Text(
                      "${tempGrade['grade']} (${tempGrade['amp']})",
                      style: TextStyle(color: tempGrade['color'] as Color, fontSize: 9, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              // 직관적인 5단계 온도 그라데이션 바
              Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    width: 90,
                    height: 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFF2979FF), // 0도 이하 C등급 극저온 파랑
                          Color(0xFF00E5FF), // 10~15도 A(저온) 하늘
                          Color(0xFF00E676), // 15~45도 S등급 최적 초록
                          Color(0xFFFFD600), // 45~48도 A(고온) 노랑
                          Color(0xFFFF9100), // 48~54도 B등급 주황
                          Color(0xFFFF5252), // 55도 이상 D등급 빨강
                        ],
                      ),
                    ),
                  ),
                  // 현재 온도 인디케이터 핀 (-10도 ~ 60도)
                  Positioned(
                    left: (((_batteryTemp + 10) / 70.0).clamp(0.0, 1.0) * 84),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: Colors.black, blurRadius: 2)],
                      ),
                    ),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF13171D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF222A35)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: const TextStyle(color: Colors.white54, fontSize: 9)),
          const SizedBox(height: 2),
          child,
        ],
      ),
    );
  }
}
