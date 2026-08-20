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

  // CAN 순정 데이터 변수 (evkmc 역공학 공식 기반)
  double soc = 0.0;
  double packVolt = 0.0;
  double packCurr = 0.0;
  double speed = 0.0;
  double temp = 0.0;
  double chargeKw = 0.0;
  double? initialSoc;

  // 운행 누적 및 전비 변수
  int totalSeconds = 0;
  double tripDistance = 0.0;
  double historicalEfficiency = 5.3;

  // 5초 평균 전비 큐 (실시간 색상 제어)
  final Queue<double> efficiencyQueue = Queue<double>();
  double smoothedEfficiency = 5.5;

  Timer? _tripTimer;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _startTimers();
  }

  @override
  void dispose() {
    _tripTimer?.cancel();
    connection?.dispose();
    super.dispose();
  }

  void _startTimers() {
    _tripTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        totalSeconds++;
        if (speed > 0) {
          tripDistance += (speed / 3600.0);
        }

        // 순간 전비 계산 & 5초 이동평균 버퍼
        double instantEfficiency = 5.5;
        double powerKw = (packVolt * packCurr) / 1000.0;
        if (powerKw < 0) {
          instantEfficiency = 9.9; // 회생제동 충전
        } else if (powerKw > 0.5 && speed > 1.0) {
          instantEfficiency = (speed / powerKw).clamp(0.0, 15.0);
        }

        efficiencyQueue.addLast(instantEfficiency);
        if (efficiencyQueue.length > 5) efficiencyQueue.removeFirst();
        smoothedEfficiency = efficiencyQueue.reduce((a, b) => a + b) / efficiencyQueue.length;

        // 누적 전비 (EMA)
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

  // 5단계 실시간 전비 컬러
  Color _getEfficiencyColor(double eff) {
    if (eff >= 7.0) return const Color(0xFF29B6F6); // 🔵 스카이블루 (초고효율)
    if (eff >= 5.5) return const Color(0xFF00E676); // 🟢 네온그린 (고효율)
    if (eff >= 4.5) return const Color(0xFFFFEE58); // 🟡 옐로우 (양호)
    if (eff >= 4.0) return const Color(0xFFFFA726); // 🟠 오렌지 (보통)
    return const Color(0xFFFF5252);                 // 🔴 레드 (급가속/부하)
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  // 블루투스 네이티브 SPP 소켓 연결
  void _connectToEvLogger() async {
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
        FlutterBluetoothSerial.instance.startDiscovery().listen((r) {
          if (r.device.name?.contains('EvLogger') == true) {
            _startConnection(r.device);
          }
        });
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
      conn.input?.listen(_onDataReceived).onDone(() {
        setState(() => isConnected = false);
      });
    } catch (e) {
      setState(() => isConnecting = false);
    }
  }

  // evkmc 앱 순정 CAN 패킷 파싱 로직
  void _onDataReceived(Uint8List rawBytes) {
    if (rawBytes.length >= 8) {
      ByteData view = ByteData.sublistView(rawBytes);
      setState(() {
        soc = (rawBytes[1] * 0.5).clamp(0.0, 100.0);
        if (initialSoc == null && soc > 0) initialSoc = soc;

        packVolt = view.getUint16(2, Endian.little).toDouble();
        packCurr = (view.getUint16(4, Endian.little) - 1000).toDouble();
        temp = (rawBytes[6] - 40).toDouble();

        double powerKw = (packVolt * packCurr) / 1000.0;
        chargeKw = powerKw < 0 ? powerKw.abs() : 0.0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Color dynamicColor = _getEfficiencyColor(smoothedEfficiency);
    double ecoRange = soc * 2.3;
    double remainingKWh = 38.7 * (soc / 100.0);
    double bmsRange = remainingKWh * historicalEfficiency;
    double usedSoc = initialSoc != null ? math.max(0.0, initialSoc! - soc) : 0.0;
    double chargePercentPerHour = chargeKw > 0 ? (chargeKw / 0.387) : 0.0;
    double powerKw = (packVolt * packCurr) / 1000.0;

    return Scaffold(
      backgroundColor: _getBgColor(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Column(
            children: [
              // 헤더 바 (브랜드명, 테마 선택 드롭다운, 블루투스 연결 버튼)
              _buildHeader(dynamicColor),
              const SizedBox(height: 6),

              // 메인 바디 (선택된 테마 렌더링)
              Expanded(
                child: _buildThemeBody(
                  dynamicColor: dynamicColor,
                  ecoRange: ecoRange,
                  bmsRange: bmsRange,
                  chargePercentPerHour: chargePercentPerHour,
                  powerKw: powerKw,
                ),
              ),

              const SizedBox(height: 6),

              // 하단 공통 트립 바
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
            // 테마 선택기
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(16),
              ),
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
            // 블루투스 버튼
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
                      isConnected ? 'EvLogger 연결됨' : (isConnecting ? '연결 중...' : '블루투스 연결'),
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
  }) {
    switch (currentTheme) {
      case DashboardTheme.originalNeon:
        return _buildOriginalNeonBody(dynamicColor, ecoRange, bmsRange, chargePercentPerHour);
      case DashboardTheme.teslaMinimal:
        return _buildTeslaBody(dynamicColor, ecoRange, powerKw);
      case DashboardTheme.bmwDynamic:
        return _buildBmwBody(dynamicColor, ecoRange, powerKw);
      case DashboardTheme.bydOcean:
        return _buildBydBody(dynamicColor, ecoRange, bmsRange, chargePercentPerHour);
    }
  }

  // 1. 오리지널 네온 UI
  Widget _buildOriginalNeonBody(Color dynamicColor, double ecoRange, double bmsRange, double chargePercentPerHour) {
    return Row(
      children: [
        Expanded(
          flex: 10,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildDataCard('연비 주행거리 (2.3km/%)', ecoRange.toStringAsFixed(1), 'km', const Color(0xFF00E676), const Color(0xFF00E676)),
              const SizedBox(height: 14),
              _buildDataCard('BMS 주행가능거리', bmsRange.toStringAsFixed(1), 'km', const Color(0xFFECEFF1), const Color(0xFF37474F)),
            ],
          ),
        ),
        Expanded(
          flex: 16,
          child: Center(
            child: SizedBox(
              width: 250,
              height: 250,
              child: CustomPaint(
                painter: HtmlExactGaugePainter(soc: soc, targetColor: dynamicColor),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('BATTERY', style: TextStyle(color: Color(0xFF78909C), fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 3.0)),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(soc.toStringAsFixed(1), style: TextStyle(color: dynamicColor, fontSize: 52, fontWeight: FontWeight.w900, height: 1.0)),
                          const Text('%', style: TextStyle(color: Color(0xFF00E676), fontSize: 24, fontWeight: FontWeight.bold)),
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
              _buildDataCard('실시간 충전량', chargeKw.toStringAsFixed(1), 'kW', const Color(0xFFFFB300), const Color(0xFFFFB300), subText: '(${chargePercentPerHour.toStringAsFixed(1)} %/h)', valFontSize: 24),
              const SizedBox(height: 14),
              _buildDataCard('주행 속도', speed.round().toString(), 'km/h', const Color(0xFFECEFF1), const Color(0xFF37474F)),
            ],
          ),
        ),
      ],
    );
  }

  // 2. 테슬라 스타일
  Widget _buildTeslaBody(Color dynamicColor, double ecoRange, double powerKw) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: BoxDecoration(color: const Color(0xFF222226), borderRadius: BorderRadius.circular(16)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('BATTERY LEVEL', style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
                Text('${soc.toStringAsFixed(0)}%', style: TextStyle(color: dynamicColor, fontSize: 48, fontWeight: FontWeight.w900)),
              ]),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                const Text('ESTIMATED RANGE', style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
                Text('${ecoRange.toStringAsFixed(0)} km', style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 40, fontWeight: FontWeight.bold)),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: (soc / 100).clamp(0.0, 1.0),
            minHeight: 12,
            backgroundColor: const Color(0xFF222226),
            valueColor: AlwaysStoppedAnimation<Color>(dynamicColor),
          ),
        ),
        const SizedBox(height: 12),
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

  // 3. BMW M 스타일
  Widget _buildBmwBody(Color dynamicColor, double ecoRange, double powerKw) {
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF141A29),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE9271D), width: 2),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('//M POWER (kW)', style: TextStyle(color: Color(0xFFE9271D), fontSize: 14, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                const SizedBox(height: 6),
                Text(powerKw.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                Text('${packVolt.toStringAsFixed(0)}V / ${packCurr.toStringAsFixed(0)}A', style: const TextStyle(color: Colors.white54, fontSize: 13)),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF141A29),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF0066B1), width: 2),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('BATTERY SOC', style: TextStyle(color: Color(0xFF0066B1), fontSize: 14, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                const SizedBox(height: 6),
                Text('${soc.toStringAsFixed(0)}%', style: TextStyle(color: dynamicColor, fontSize: 44, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                Text('EST. ${ecoRange.toStringAsFixed(0)} km', style: const TextStyle(color: Color(0xFF00FF88), fontSize: 14, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // 4. BYD 오션 스타일
  Widget _buildBydBody(Color dynamicColor, double ecoRange, double bmsRange, double chargePercentPerHour) {
    return Row(
      children: [
        Expanded(
          flex: 4,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF06213F),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('BLADE BATTERY SOC', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('${soc.toStringAsFixed(1)} %', style: TextStyle(color: dynamicColor, fontSize: 44, fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: (soc / 100).clamp(0.0, 1.0),
                  backgroundColor: Colors.black38,
                  valueColor: AlwaysStoppedAnimation<Color>(dynamicColor),
                ),
                const SizedBox(height: 10),
                Text('주행 가능: ${ecoRange.toStringAsFixed(1)} km', style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 6,
          child: Column(
            children: [
              Expanded(child: _buildDataCard('실시간 충전량', chargeKw.toStringAsFixed(1), 'kW', const Color(0xFFFFB300), const Color(0xFFFFB300), subText: '(${chargePercentPerHour.toStringAsFixed(1)} %/h)')),
              const SizedBox(height: 8),
              Expanded(child: _buildDataCard('BMS 주행가능거리', bmsRange.toStringAsFixed(1), 'km', Colors.white, const Color(0xFF37474F))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(double usedSoc) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 18),
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

  Widget _buildDataCard(String label, String value, String unit, Color valColor, Color barColor, {String? subText, double valFontSize = 28}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
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
            left: -18,
            top: -14,
            bottom: -14,
            child: Container(width: 5, color: barColor),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label, style: const TextStyle(color: Color(0xFF90A4AE), fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(value, style: TextStyle(color: valColor, fontSize: valFontSize, fontWeight: FontWeight.w800)),
                  const SizedBox(width: 4),
                  Text(unit, style: const TextStyle(color: Color(0xFF78909C), fontSize: 13, fontWeight: FontWeight.w500)),
                  if (subText != null) ...[
                    const Spacer(),
                    Text(subText, style: const TextStyle(color: Color(0xFF78909C), fontSize: 12, fontWeight: FontWeight.w500)),
                  ],
                ],
              ),
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
    return Container(width: 1, height: 26, color: const Color(0xFF1C212C));
  }
}

// 상단 시작 원형 게이지
class HtmlExactGaugePainter extends CustomPainter {
  final double soc;
  final Color targetColor;
  HtmlExactGaugePainter({required this.soc, required this.targetColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 24) / 2;

    // 배경 트랙
    final bgPaint = Paint()
      ..color = const Color(0xFF161A22)
      ..strokeWidth = 18
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, bgPaint);

    // 활성 게이지 (상단 12시 방향 시작)
    final sweepAngle = 2 * math.pi * (soc / 100.0).clamp(0.0, 1.0);
    final rect = Rect.fromCircle(center: center, radius: radius);

    final progressPaint = Paint()
      ..color = targetColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 18
      ..style = PaintingStyle.stroke;

    canvas.drawArc(rect, -math.pi / 2, sweepAngle, false, progressPaint);
  }

  @override
  bool shouldRepaint(covariant HtmlExactGaugePainter oldDelegate) =>
      oldDelegate.soc != soc || oldDelegate.targetColor != targetColor;
}
