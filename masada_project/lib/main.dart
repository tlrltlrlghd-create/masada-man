import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const MaterialApp(
    home: MasadaDashboardApp(),
    debugShowCheckedModeBanner: false,
  ));
}

enum DashboardTheme { originalNeon, teslaMinimal, bmwDynamic, bydOcean }

class MasadaDashboardApp extends StatefulWidget {
  const MasadaDashboardApp({super.key});

  @override
  State<MasadaDashboardApp> createState() => _MasadaDashboardAppState();
}

class _MasadaDashboardAppState extends State<MasadaDashboardApp> {
  DashboardTheme currentTheme = DashboardTheme.originalNeon;
  BluetoothConnection? connection;
  bool isConnecting = false;
  bool isConnected = false;

  // 바이트 정렬 버퍼
  final List<int> _rawBuffer = [];

  // CAN 순정 데이터
  double soc = 0.0;
  double packVolt = 0.0;
  double packCurr = 0.0;
  double speed = 0.0;
  double temp = 0.0;
  double chargeKw = 0.0;
  double smoothedChargeKw = 0.0;
  final Queue<double> _chargePowerBuffer = Queue<double>();

  double? initialSoc;
  int totalSeconds = 0;
  double tripDistance = 0.0;
  double historicalEfficiency = 5.3;
  final Queue<double> efficiencyQueue = Queue<double>();
  double smoothedEfficiency = 5.5;

  Timer? _tripTimer;
  Timer? _autoReconnectTimer;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    await _requestPermissions();
    _startTimers();
    _connectToEvLogger();
    // 8초 주기로 완전히 끊겼을 때만 단일 재연결 시도
    _autoReconnectTimer = Timer.periodic(const Duration(seconds: 8), (timer) {
      if (!isConnected && !isConnecting) {
        _connectToEvLogger();
      }
    });
  }

  @override
  void dispose() {
    _tripTimer?.cancel();
    _autoReconnectTimer?.cancel();
    connection?.dispose();
    super.dispose();
  }

  void _startTimers() {
    _tripTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        totalSeconds++;
        if (speed > 0) tripDistance += (speed / 3600.0);

        _chargePowerBuffer.addLast(chargeKw);
        if (_chargePowerBuffer.length > 5) _chargePowerBuffer.removeFirst();
        smoothedChargeKw = _chargePowerBuffer.reduce((a, b) => a + b) / _chargePowerBuffer.length;

        double instantEfficiency = 5.5;
        double powerKw = (packVolt * packCurr) / 1000.0;
        if (powerKw < 0) {
          instantEfficiency = 9.9;
        } else if (powerKw > 0.5 && speed > 1.0) {
          instantEfficiency = (speed / powerKw).clamp(0.0, 15.0);
        }

        efficiencyQueue.addLast(instantEfficiency);
        if (efficiencyQueue.length > 5) efficiencyQueue.removeFirst();
        smoothedEfficiency = efficiencyQueue.reduce((a, b) => a + b) / efficiencyQueue.length;
        historicalEfficiency = (historicalEfficiency * 0.8) + (instantEfficiency * 0.2);
      });
    });
  }

  String _formatDuration(int seconds) {
    int h = seconds ~/ 3600;
    int m = (seconds % 3600) ~/ 60;
    int s = seconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> _calcChargeEta(double curSoc, double curKw, double curTemp) {
    if (curKw <= 0.3 || curSoc >= 99.5) {
      return {'to80': 0, 'to100': 0, 'isPreheating': false, 'heatMins': 0};
    }
    const double totalKWh = 38.7;

    if (curKw <= 7.0) {
      double remKwh80 = math.max(0.0, (80.0 - curSoc) / 100.0 * totalKWh);
      double remKwh100 = math.max(0.0, (100.0 - curSoc) / 100.0 * totalKWh);
      return {
        'to80': (remKwh80 / curKw * 60).round(),
        'to100': (remKwh100 / curKw * 60).round(),
        'isPreheating': false,
        'heatMins': 0,
      };
    }

    double heatMinutes = 0.0;
    bool isPreheating = false;

    if (curTemp < 15.0) {
      isPreheating = true;
      double energyToHeat = (15.0 - curTemp) * 0.083;
      double heatingPower = math.max(5.0, math.min(curKw, 20.0));
      heatMinutes = (energyToHeat / heatingPower) * 60.0;
    }

    double minutesTo80 = 0.0;
    double minutesTo100 = 0.0;
    double effectiveKw = math.max(curKw, 25.0);

    if (curSoc < 80.0) {
      double kwh1 = (80.0 - curSoc) / 100.0 * totalKWh;
      minutesTo80 = (kwh1 / effectiveKw) * 60;
      minutesTo100 += minutesTo80;
    }

    if (curSoc < 90.0) {
      double startSoc2 = math.max(80.0, curSoc);
      double kwh2 = (90.0 - startSoc2) / 100.0 * totalKWh;
      minutesTo100 += (kwh2 / 15.0) * 60;
    }

    if (curSoc < 100.0) {
      double startSoc3 = math.max(90.0, curSoc);
      double kwh3 = (100.0 - startSoc3) / 100.0 * totalKWh;
      minutesTo100 += (kwh3 / 6.0) * 60;
    }

    return {
      'to80': (minutesTo80 + heatMinutes).round(),
      'to100': (minutesTo100 + heatMinutes).round(),
      'isPreheating': isPreheating,
      'heatMins': heatMinutes.round(),
    };
  }

  Color _getEfficiencyColor(double eff) {
    if (eff >= 7.0) return const Color(0xFF29B6F6);
    if (eff >= 5.5) return const Color(0xFF00E676);
    if (eff >= 4.5) return const Color(0xFFFFEE58);
    if (eff >= 4.0) return const Color(0xFFFFA726);
    return const Color(0xFFFF5252);
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  void _connectToEvLogger() async {
    if (isConnected || isConnecting) return;
    setState(() => isConnecting = true);

    try {
      List<BluetoothDevice> devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      BluetoothDevice? targetDevice;
      for (var d in devices) {
        if (d.name?.contains('EvLogger') == true || d.address.contains('F0:D6')) {
          targetDevice = d;
          break;
        }
      }

      if (targetDevice != null) {
        _startConnection(targetDevice);
      } else {
        setState(() => isConnecting = false);
      }
    } catch (e) {
      setState(() => isConnecting = false);
    }
  }

  void _startConnection(BluetoothDevice device) async {
    try {
      BluetoothConnection conn = await BluetoothConnection.toAddress(device.address);
      setState(() {
        connection = conn;
        isConnected = true;
        isConnecting = false;
      });

      conn.input?.listen(_handleStreamData).onDone(() {
        setState(() {
          isConnected = false;
          connection = null;
        });
      });
    } catch (e) {
      setState(() {
        isConnected = false;
        isConnecting = false;
        connection = null;
      });
    }
  }

  // 스트림 조각 모음 및 동기화 파서
  void _handleStreamData(Uint8List chunk) {
    _rawBuffer.addAll(chunk);

    // 8바이트 이상 쌓였을 때 유효 패킷 탐색
    while (_rawBuffer.length >= 8) {
      // SOC 유효 범위 (0~200 raw = 0~100%) 검증
      int candidateSocRaw = _rawBuffer[1];
      double candidateSoc = candidateSocRaw * 0.5;

      // 팩 전압 유효 범위 (마사다 LFP 250V ~ 420V)
      int vRaw = _rawBuffer[2] | (_rawBuffer[3] << 8);
      double candidateVolt = vRaw.toDouble();

      if (candidateSoc >= 0.0 && candidateSoc <= 100.0 && candidateVolt >= 200.0 && candidateVolt <= 500.0) {
        // 유효 패킷 발견: 8바이트 추출 파싱
        Uint8List packet = Uint8List.fromList(_rawBuffer.sublist(0, 8));
        _rawBuffer.removeRange(0, 8);
        _parseValidPacket(packet);
      } else {
        // 동기화가 밀렸으면 1바이트 버리고 다음 바이트 탐색
        _rawBuffer.removeAt(0);
      }
    }

    if (_rawBuffer.length > 64) _rawBuffer.clear();
  }

  void _parseValidPacket(Uint8List p) {
    setState(() {
      // 1. 배터리 잔량 SOC (%)
      soc = (p[1] * 0.5).clamp(0.0, 100.0);
      if (initialSoc == null && soc > 0) initialSoc = soc;

      // 2. 팩 전압 (V)
      packVolt = (p[2] | (p[3] << 8)).toDouble();

      // 3. 팩 전류 (A) - Offset 1000, 0.1A 단위 보정
      int rawCurr = p[4] | (p[5] << 8);
      packCurr = (rawCurr - 1000).toDouble();

      // 4. 배터리 온도 (℃)
      temp = (p[6] - 40).toDouble();

      // 5. 충전 전력 계산
      double pKw = (packVolt * packCurr) / 1000.0;
      if (pKw < 0) {
        chargeKw = pKw.abs().clamp(0.0, 60.0);
      } else {
        chargeKw = 0.0;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    Color dynamicColor = _getEfficiencyColor(smoothedEfficiency);
    double ecoRange = soc * 2.3;
    double remainingKWh = 38.7 * (soc / 100.0);
    double bmsRange = remainingKWh * historicalEfficiency;
    double usedSoc = initialSoc != null ? math.max(0.0, initialSoc! - soc) : 0.0;
    double chargePercentPerHour = smoothedChargeKw > 0 ? (smoothedChargeKw / 0.387) : 0.0;
    double powerKw = (packVolt * packCurr) / 1000.0;
    var eta = _calcChargeEta(soc, smoothedChargeKw > 0 ? smoothedChargeKw : chargeKw, temp);

    return Scaffold(
      backgroundColor: _getBgColor(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
          child: Column(
            children: [
              _buildHeader(dynamicColor),
              const SizedBox(height: 4),
              Expanded(
                child: _buildThemeBody(
                  dynamicColor: dynamicColor,
                  ecoRange: ecoRange,
                  bmsRange: bmsRange,
                  chargePercentPerHour: chargePercentPerHour,
                  powerKw: powerKw,
                  eta: eta,
                ),
              ),
              const SizedBox(height: 6),
              _buildBidirectionalPowerBar(powerKw),
              const SizedBox(height: 6),
              _buildFooter(usedSoc),
            ],
          ),
        ),
      ),
    );
  }

  Color _getBgColor() {
    switch (currentTheme) {
      case DashboardTheme.originalNeon: return const Color(0xFF08090C);
      case DashboardTheme.teslaMinimal: return const Color(0xFF141416);
      case DashboardTheme.bmwDynamic: return const Color(0xFF0B0D14);
      case DashboardTheme.bydOcean: return const Color(0xFF021020);
    }
  }

  Widget _buildHeader(Color dynamicColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        RichText(
          text: TextSpan(
            text: 'MASADA VAN ',
            style: const TextStyle(color: Color(0xFF78909C), fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 1.5),
            children: [
              TextSpan(text: 'EV MONITOR', style: TextStyle(color: dynamicColor)),
            ],
          ),
        ),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(16)),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<DashboardTheme>(
                  value: currentTheme,
                  dropdownColor: const Color(0xFF161A22),
                  icon: Icon(Icons.palette_outlined, color: dynamicColor, size: 18),
                  onChanged: (newTheme) {
                    if (newTheme != null) setState(() => currentTheme = newTheme);
                  },
                  items: const [
                    DropdownMenuItem(value: DashboardTheme.originalNeon, child: Text('🟢 오리지널 네온', style: TextStyle(color: Colors.white, fontSize: 12))),
                    DropdownMenuItem(value: DashboardTheme.teslaMinimal, child: Text('⚡ 테슬라 스타일', style: TextStyle(color: Colors.white, fontSize: 12))),
                    DropdownMenuItem(value: DashboardTheme.bmwDynamic, child: Text('🔴 BMW M 스타일', style: TextStyle(color: Colors.white, fontSize: 12))),
                    DropdownMenuItem(value: DashboardTheme.bydOcean, child: Text('🌊 BYD 오션 스타일', style: TextStyle(color: Colors.white, fontSize: 12))),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: isConnected ? () => connection?.finish() : _connectToEvLogger,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: isConnected ? const Color(0x1400E676) : const Color(0x14FF5252),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: isConnected ? const Color(0x4000E676) : const Color(0x40FF5252)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isConnected ? const Color(0xFF00E676) : const Color(0xFFFF5252),
                        boxShadow: [
                          BoxShadow(
                            color: isConnected ? const Color(0xFF00E676) : const Color(0xFFFF5252),
                            blurRadius: 8,
                          )
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isConnected ? 'EvLogger 연결됨' : (isConnecting ? '자동 연결 중...' : '블루투스 연결'),
                      style: TextStyle(
                        color: isConnected ? const Color(0xFF00E676) : const Color(0xFFFF5252),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
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

  Widget _buildThemeBody({
    required Color dynamicColor,
    required double ecoRange,
    required double bmsRange,
    required double chargePercentPerHour,
    required double powerKw,
    required Map<String, dynamic> eta,
  }) {
    switch (currentTheme) {
      case DashboardTheme.originalNeon:
        return _buildOriginalNeonBody(dynamicColor, ecoRange, bmsRange, chargePercentPerHour, eta);
      case DashboardTheme.teslaMinimal:
        return _buildTeslaBody(dynamicColor, ecoRange, powerKw, eta);
      case DashboardTheme.bmwDynamic:
        return _buildBmwBody(dynamicColor, ecoRange, powerKw, eta);
      case DashboardTheme.bydOcean:
        return _buildBydBody(dynamicColor, ecoRange, bmsRange, chargePercentPerHour, eta);
    }
  }

  Widget _buildOriginalNeonBody(Color dynamicColor, double ecoRange, double bmsRange, double chargePercentPerHour, Map<String, dynamic> eta) {
    String etaText = '';
    if (chargeKw > 0.3) {
      if (eta['isPreheating'] == true && eta['heatMins'] > 0) {
        etaText = '[예열 +${eta['heatMins']}분] 완충 약 ${eta['to100']}분';
      } else if (soc < 80.0) {
        etaText = '80% 약 ${eta['to80']}분 | 완충 약 ${eta['to100']}분';
      } else {
        etaText = '완충까지 약 ${eta['to100']}분 (감속구간)';
      }
    }

    return Row(
      children: [
        Expanded(
          flex: 10,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildDataCard('연비 주행거리 (2.3km/%)', ecoRange.toStringAsFixed(1), 'km', const Color(0xFF00E676), const Color(0xFF00E676)),
              const SizedBox(height: 12),
              _buildDataCard('BMS 주행가능거리', bmsRange.toStringAsFixed(1), 'km', const Color(0xFFECEFF1), const Color(0xFF37474F)),
            ],
          ),
        ),
        Expanded(
          flex: 16,
          child: Center(
            child: SizedBox(
              width: 230,
              height: 230,
              child: CustomPaint(
                painter: HtmlExactGaugePainter(soc: soc, targetColor: dynamicColor),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('BATTERY', style: TextStyle(color: Color(0xFF78909C), fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 3.0)),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(soc.toStringAsFixed(1), style: TextStyle(color: dynamicColor, fontSize: 48, fontWeight: FontWeight.w900, height: 1.0)),
                          const Text('%', style: TextStyle(color: Color(0xFF00E676), fontSize: 22, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          flex: 10,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildDataCard(
                '실시간 충전량',
                chargeKw.toStringAsFixed(1),
                'kW',
                const Color(0xFFFFB300),
                const Color(0xFFFFB300),
                subText: '(${chargePercentPerHour.toStringAsFixed(1)} %/h)',
                bottomInfo: etaText.isNotEmpty ? etaText : null,
                valFontSize: 22,
              ),
              const SizedBox(height: 12),
              _buildDataCard('주행 속도', speed.round().toString(), 'km/h', const Color(0xFFECEFF1), const Color(0xFF37474F)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTeslaBody(Color dynamicColor, double ecoRange, double powerKw, Map<String, dynamic> eta) {
    String etaText = chargeKw > 0.3 ? (eta['isPreheating'] ? '[예열] 완충 약 ${eta['to100']}분' : (soc < 80 ? '80% 약 ${eta['to80']}분 | 완충 약 ${eta['to100']}분' : '완충 약 ${eta['to100']}분')) : '';
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(color: const Color(0xFF222226), borderRadius: BorderRadius.circular(16)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('BATTERY LEVEL', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
                Text('${soc.toStringAsFixed(0)}%', style: TextStyle(color: dynamicColor, fontSize: 42, fontWeight: FontWeight.w900)),
              ]),
              if (etaText.isNotEmpty)
                Text(etaText, style: const TextStyle(color: Color(0xFFFFB300), fontSize: 13, fontWeight: FontWeight.bold)),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                const Text('ESTIMATED RANGE', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
                Text('${ecoRange.toStringAsFixed(0)} km', style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 36, fontWeight: FontWeight.bold)),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: (soc / 100).clamp(0.0, 1.0),
            minHeight: 10,
            backgroundColor: const Color(0xFF222226),
            valueColor: AlwaysStoppedAnimation<Color>(dynamicColor),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildDataCard('실시간 출력/충전', '${powerKw.toStringAsFixed(1)}', 'kW', dynamicColor, dynamicColor)),
              const SizedBox(width: 12),
              Expanded(child: _buildDataCard('주행 속도', speed.round().toString(), 'km/h', Colors.white, const Color(0xFF38BDF8))),
            ],
          ),
        )
      ],
    );
  }

  Widget _buildBmwBody(Color dynamicColor, double ecoRange, double powerKw, Map<String, dynamic> eta) {
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF141A29),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE9271D), width: 2),
            ),
            child: Column(
              mainAxisAlignment: CenterAxisAlignment.center,
              children: [
                const Text('//M POWER (kW)', style: TextStyle(color: Color(0xFFE9271D), fontSize: 13, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                const SizedBox(height: 4),
                Text(powerKw.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                Text('${packVolt.toStringAsFixed(0)}V / ${packCurr.toStringAsFixed(0)}A', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF141A29),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF0066B1), width: 2),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('BATTERY SOC', style: TextStyle(color: Color(0xFF0066B1), fontSize: 13, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                const SizedBox(height: 4),
                Text('${soc.toStringAsFixed(0)}%', style: TextStyle(color: dynamicColor, fontSize: 40, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                Text('EST. ${ecoRange.toStringAsFixed(0)} km', style: const TextStyle(color: Color(0xFF00FF88), fontSize: 13, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBydBody(Color dynamicColor, double ecoRange, double bmsRange, double chargePercentPerHour, Map<String, dynamic> eta) {
    String etaText = chargeKw > 0.3 ? (eta['isPreheating'] ? '[예열] 완충 약 ${eta['to100']}분' : (soc < 80 ? '80% 약 ${eta['to80']}분 | 완충 약 ${eta['to100']}분' : '완충 약 ${eta['to100']}분')) : '';
    return Row(
      children: [
        Expanded(
          flex: 4,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF06213F),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('BLADE BATTERY SOC', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text('${soc.toStringAsFixed(1)} %', style: TextStyle(color: dynamicColor, fontSize: 38, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: (soc / 100).clamp(0.0, 1.0),
                  backgroundColor: Colors.black38,
                  valueColor: AlwaysStoppedAnimation<Color>(dynamicColor),
                ),
                const SizedBox(height: 8),
                Text('주행 가능: ${ecoRange.toStringAsFixed(1)} km', style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 6,
          child: Column(
            children: [
              Expanded(
                child: _buildDataCard(
                  '실시간 충전량',
                  chargeKw.toStringAsFixed(1),
                  'kW',
                  const Color(0xFFFFB300),
                  const Color(0xFFFFB300),
                  subText: '(${chargePercentPerHour.toStringAsFixed(1)} %/h)',
                  bottomInfo: etaText.isNotEmpty ? etaText : null,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(child: _buildDataCard('BMS 주행가능거리', bmsRange.toStringAsFixed(1), 'km', Colors.white, const Color(0xFF37474F))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBidirectionalPowerBar(double powerKw) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1116),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1C212C)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('◀ 회생제동 (REGEN)', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 10, fontWeight: FontWeight.bold)),
              Text(
                '실시간 파워: ${powerKw.toStringAsFixed(1)} kW',
                style: TextStyle(
                  color: powerKw < 0 ? const Color(0xFF00FF88) : (powerKw > 30 ? const Color(0xFFFF3366) : const Color(0xFFFFB800)),
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  fontFamily: 'monospace',
                ),
              ),
              const Text('가속 출력 (POWER) ▶', style: TextStyle(color: Color(0xFFFF5252), fontSize: 10, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 10,
            child: CustomPaint(
              painter: BidirectionalPowerPainter(powerKw: powerKw),
              child: Container(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(double usedSoc) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1116),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1C212C)),
      ),
      child: Row(
        children: [
          _buildSubItem('운행 시간', _formatDuration(totalSeconds), const Color(0xFF00E5FF)),
          _buildSubDivider(),
          _buildSubItem('운행 거리', '${tripDistance.toStringAsFixed(1)} km', const Color(0xFF00E5FF)),
          _buildSubDivider(),
          _buildSubItem('배터리 사용량', '${usedSoc.toStringAsFixed(1)} %', const Color(0xFFFF5252)),
          _buildSubDivider(),
          _buildSubItem('배터리 온도', '${temp.toStringAsFixed(1)} °C', const Color(0xFF00E5FF)),
        ],
      ),
    );
  }

  Widget _buildDataCard(
    String label,
    String value,
    String unit,
    Color valColor,
    Color barColor, {
    String? subText,
    String? bottomInfo,
    double valFontSize = 24,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF13161C), Color(0xFF0E1015)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF222733)),
      ),
      child: Stack(
        children: [
          Positioned(
            left: -16,
            top: -10,
            bottom: -10,
            child: Container(width: 4, color: barColor),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label, style: const TextStyle(color: Color(0xFF90A4AE), fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(value, style: TextStyle(color: valColor, fontSize: valFontSize, fontWeight: FontWeight.w800)),
                  const SizedBox(width: 4),
                  Text(unit, style: const TextStyle(color: Color(0xFF78909C), fontSize: 12, fontWeight: FontWeight.w500)),
                  if (subText != null) ...[
                    const Spacer(),
                    Text(subText, style: const TextStyle(color: Color(0xFF78909C), fontSize: 11, fontWeight: FontWeight.w500)),
                  ],
                ],
              ),
              if (bottomInfo != null) ...[
                const SizedBox(height: 4),
                Text(bottomInfo, style: const TextStyle(color: Color(0xFF00FF88), fontSize: 11, fontWeight: FontWeight.bold)),
              ]
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSubItem(String label, String value, Color valColor) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF78909C), fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(color: valColor, fontSize: 15, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _buildSubDivider() {
    return Container(width: 1, height: 24, color: const Color(0xFF1C212C));
  }
}

class HtmlExactGaugePainter extends CustomPainter {
  final double soc;
  final Color targetColor;
  HtmlExactGaugePainter({required this.soc, required this.targetColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 24) / 2;

    final bgPaint = Paint()
      ..color = const Color(0xFF161A22)
      ..strokeWidth = 16
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, bgPaint);

    final sweepAngle = 2 * math.pi * (soc / 100.0).clamp(0.0, 1.0);
    final rect = Rect.fromCircle(center: center, radius: radius);

    final progressPaint = Paint()
      ..color = targetColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 16
      ..style = PaintingStyle.stroke;

    canvas.drawArc(rect, -math.pi / 2, sweepAngle, false, progressPaint);
  }

  @override
  bool shouldRepaint(covariant HtmlExactGaugePainter oldDelegate) =>
      oldDelegate.soc != soc || oldDelegate.targetColor != targetColor;
}

class BidirectionalPowerPainter extends CustomPainter {
  final double powerKw;
  BidirectionalPowerPainter({required this.powerKw});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;
    final rrect = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width, size.height), const Radius.circular(5));

    final bgPaint = Paint()..color = const Color(0xFF161A22);
    canvas.drawRRect(rrect, bgPaint);

    final centerLinePaint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 2;
    canvas.drawLine(Offset(center, 0), Offset(center, size.height), centerLinePaint);

    if (powerKw < 0) {
      double regenRatio = (powerKw.abs() / 25.0).clamp(0.0, 1.0);
      double barWidth = center * regenRatio;
      final regenPaint = Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFF00E5FF), Color(0xFF00FF88)],
        ).createShader(Rect.fromLTWH(center - barWidth, 0, barWidth, size.height));
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(center - barWidth, 0, barWidth, size.height), const Radius.circular(5)),
        regenPaint,
      );
    } else if (powerKw > 0) {
      double powerRatio = (powerKw / 60.0).clamp(0.0, 1.0);
      double barWidth = (size.width - center) * powerRatio;
      Color barColor = powerKw > 35 ? const Color(0xFFFF3366) : const Color(0xFFFFB800);
      final powerPaint = Paint()..color = barColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(center, 0, barWidth, size.height), const Radius.circular(5)),
        powerPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant BidirectionalPowerPainter oldDelegate) => oldDelegate.powerKw != powerKw;
}
