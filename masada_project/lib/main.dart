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
  // 모드 전환 변수
  bool _isCampingMode = false;

  // 배터리 팩 기준 용량 (마사다 밴 = 38.7 kWh)
  static const double _batteryTotalKwh = 38.7;

  // 블루투스 통신 관련
  BluetoothConnection? _connection;
  bool _isConnected = false;
  bool _isConnecting = false;
  final List<int> _rxBuffer = [];
  Timer? _autoConnectTimer;

  // 실시간 전기차 데이터
  double _soc = 87.0;            // 배터리 잔량 (%)
  double _voltage = 318.0;       // 배터리 전압 (V)
  double _current = 1.0;         // 배터리 전류 (A)
  double _powerKw = 0.3;         // 실시간 파워 (kW)
  double _chargePowerKw = 0.0;   // 실시간 충전량 (kW)
  double _batteryTemp = 30.0;    // 배터리 온도 (°C)
  int _soh = 94;                 // 배터리 건강 상태 (%)
  double _bmsDistance = 185.2;   // BMS 주행 가능 거리 (km)
  double _efficiencyDist = 200.1;// 연비 기준 주행 가능 거리 (km)
  double _batteryUsedPct = 0.0;  // 배터리 사용량 (%)
  
  // 운행 시간
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

  // 캠핑 잔여 시간 계산 포맷 함수 (소모 전력 기반)
  String _calculateRemainingTime(double targetSoc) {
    double consumeKw = _powerKw.abs();
    
    // 소모량이 50W 미만이거나 충전 중일 때
    if (consumeKw < 0.05) {
      return "소모 없음 (대기 중)";
    }

    double currentKwh = _batteryTotalKwh * (_soc / 100.0);
    double targetKwh = _batteryTotalKwh * (targetSoc / 100.0);
    double availableKwh = currentKwh - targetKwh;

    if (availableKwh <= 0) {
      return "도달 완료";
    }

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
        if (mounted) {
          setState(() {
            _isConnecting = false;
          });
        }
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
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 12),
              // 모드에 따른 화면 렌더링
              Expanded(
                child: _isCampingMode ? _buildCampingDashboard() : _buildStandardDashboard(),
              ),
              const SizedBox(height: 10),
              _buildPowerBar(),
              const SizedBox(height: 8),
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
            // 캠핑 모드 토글 버튼
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
            // 테마 버튼
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
            // 연결 상태 버튼
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

  // 기본 주행 대시보드
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

  // 캠핑 모드 전용 대시보드
  Widget _buildCampingDashboard() {
    double consumeWatts = (_voltage * _current).abs();
    double percentPerHour = consumeWatts > 0 ? (consumeWatts / (_batteryTotalKwh * 1000)) * 100 : 0.0;

    return Row(
      children: [
        // 좌측: SOC 및 실시간 소모 전력
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
        // 우측: 20% 마진 및 0% 완전방전까지 잔여 시간 카드
        Expanded(
          flex: 6,
          child: Column(
            children: [
              Expanded(
                child: _buildCampingTimeCard(
                  title: "🛡️ 복귀 마진 (배터리 20% 도달까지)",
                  remainingTime: _calculateRemainingTime(20.0),
                  subInfo: "남은 사용 가능량: ${((_soc - 20).clamp(0, 100) * _batteryTotalKwh / 100).toStringAsFixed(1)} kWh",
                  accentColor: const Color(0xFF00E5FF),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _buildCampingTimeCard(
                  title: "⚠️ 한계 마진 (배터리 0% 완전 방전까지)",
                  remainingTime: _calculateRemainingTime(0.0),
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
    return Column(
      children: [
        Expanded(
          child: _buildCard(
            title: "실시간 충전량",
            valueText: _chargePowerKw.toStringAsFixed(1),
            unitText: "kW",
            valueColor: const Color(0xFFFFB300),
            subText: "(0.0 %/h)",
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

  Widget _buildPowerBar() {
    double normalized = ((_powerKw + 50) / 100).clamp(0.0, 1.0);

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
              Text(
                "실시간 파워: ${_powerKw.toStringAsFixed(1)} kW",
                style: const TextStyle(color: Color(0xFFFFB300), fontSize: 11, fontWeight: FontWeight.bold),
              ),
              const Text("가속 출력 (POWER) ▶", style: TextStyle(color: Colors.redAccent, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: normalized,
            backgroundColor: const Color(0xFF222A35),
            valueColor: AlwaysStoppedAnimation<Color>(
              _powerKw < 0 ? const Color(0xFFFF9100) : const Color(0xFF00E676),
            ),
            minHeight: 6,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomStatusBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _buildBottomItem("운행 시간", _formatDrivingTime(_drivingSeconds), const Color(0xFF00E5FF)),
        _buildBottomItem("배터리 건강(SOH)", "$_soh %", const Color(0xFF00E5FF)),
        _buildBottomItem("배터리 사용량", "${_batteryUsedPct.toStringAsFixed(1)} %", Colors.redAccent),
        _buildBottomItem("배터리온도", "${_batteryTemp.toStringAsFixed(1)} °C", const Color(0xFF00E5FF)),
      ],
    );
  }

  Widget _buildBottomItem(String title, String value, Color valueColor) {
    return Column(
      children: [
        Text(title, style: const TextStyle(color: Colors.white54, fontSize: 10)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(color: valueColor, fontSize: 12, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
