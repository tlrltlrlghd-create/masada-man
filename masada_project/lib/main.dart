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
  StreamSubscription<Uint8List>? _streamSub;
  bool isConnecting = false;
  bool isConnected = false;
  String connectionStatusText = '10초 후 자동 연결...';

  final List<int> _byteBuffer = [];
  String _asciiBuffer = '';

  // 실시간 DBC 물리 데이터
  double soc = 0.0;
  double packVolt = 320.0;
  double packCurr = 0.0;
  double speed = 0.0;
  double motorRpm = 0.0;
  double temp = 20.0;
  double soh = 100.0;
  double maxCellVolt = 0.0;
  double minCellVolt = 0.0;
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
  Timer? _uiRefreshTimer;
  Timer? _reconnectLoopTimer;
  Timer? _initialDelayTimer;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    _startTimers();
    await _requestPermissions();

    _initialDelayTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && !isConnected && !isConnecting) {
        _connectToEvLogger();
      }
    });

    _reconnectLoopTimer = Timer.periodic(const Duration(seconds: 8), (timer) {
      if (totalSeconds >= 10 && !isConnected && !isConnecting && connection == null && mounted) {
        _connectToEvLogger();
      }
    });
  }

  @override
  void dispose() {
    _tripTimer?.cancel();
    _uiRefreshTimer?.cancel();
    _initialDelayTimer?.cancel();
    _reconnectLoopTimer?.cancel();
    _streamSub?.cancel();
    connection?.dispose();
    super.dispose();
  }

  void _startTimers() {
    _tripTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
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

    _uiRefreshTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (!mounted) return;
      setState(() {
        if (!isConnected && !isConnecting && totalSeconds < 10) {
          connectionStatusText = '${10 - totalSeconds}초 후 자동 연결';
        }
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
    try {
      await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();
    } catch (_) {}
  }

  void _connectToEvLogger() async {
    if (isConnected || isConnecting || connection != null) return;
    if (!mounted) return;

    setState(() {
      isConnecting = true;
      connectionStatusText = '기기 탐색 중...';
    });

    try {
      List<BluetoothDevice> devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      BluetoothDevice? targetDevice;

      for (var d in devices) {
        String name = (d.name ?? '').toUpperCase();
        String addr = d.address.toUpperCase();
        if (name.contains('EVLOGGER') || name.contains('LOGGER') || name.contains('OBD') ||
            addr.contains('F0:D6') || addr.contains('F0D6')) {
          targetDevice = d;
          break;
        }
      }

      if (targetDevice == null && devices.length == 1) {
        targetDevice = devices.first;
      }

      if (targetDevice != null) {
        if (mounted) setState(() => connectionStatusText = '연결 시도 중...');
        _startConnection(targetDevice);
      } else {
        if (mounted) {
          setState(() {
            isConnecting = false;
            connectionStatusText = '블루투스 연결';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isConnecting = false;
          connectionStatusText = '블루투스 연결';
        });
      }
    }
  }

  void _startConnection(BluetoothDevice device) async {
    try {
      BluetoothConnection conn = await BluetoothConnection.toAddress(device.address).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Connection timeout'),
      );

      if (!mounted) return;
      setState(() {
        connection = conn;
        isConnected = true;
        isConnecting = false;
        connectionStatusText = 'EvLogger 연결됨';
      });

      _streamSub?.cancel();
      _streamSub = conn.input?.listen(
        _handleIncomingData,
        onDone: () {
          if (!mounted) return;
          setState(() {
            isConnected = false;
            isConnecting = false;
            connection = null;
            connectionStatusText = '연결 끊김';
          });
        },
        onError: (e) {},
        cancelOnError: false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isConnected = false;
        isConnecting = false;
        connection = null;
        connectionStatusText = '블루투스 연결';
      });
    }
  }

  void _handleIncomingData(Uint8List chunk) {
    String textChunk = String.fromCharCodes(chunk);
    _asciiBuffer += textChunk;

    if (_asciiBuffer.contains('\r') || _asciiBuffer.contains('\n')) {
      List<String> lines = _asciiBuffer.split(RegExp(r'[\r\n]+'));
      _asciiBuffer = lines.last;

      for (int i = 0; i < lines.length - 1; i++) {
        _parseAsciiLine(lines[i].trim());
      }
    }
    if (_asciiBuffer.length > 512) _asciiBuffer = '';

    _byteBuffer.addAll(chunk);

    while (_byteBuffer.length >= 12) {
      bool is7D = false;
      bool is7E = false;
      bool isMCU = false;
      bool isMeter = false;
      int headerSize = 4;

      if ((_byteBuffer[0] & 0x1F) == 0x0C && _byteBuffer[1] == 0xFF && _byteBuffer[2] == 0x7D && _byteBuffer[3] == 0x03) {
        is7D = true;
      } else if (_byteBuffer[0] == 0x03 && _byteBuffer[1] == 0x7D && _byteBuffer[2] == 0xFF && (_byteBuffer[3] & 0x1F) == 0x0C) {
        is7D = true;
      } else if ((_byteBuffer[0] & 0x1F) == 0x0C && _byteBuffer[1] == 0xFF && _byteBuffer[2] == 0x7E && _byteBuffer[3] == 0x03) {
        is7E = true;
      } else if (_byteBuffer[0] == 0x03 && _byteBuffer[1] == 0x7E && _byteBuffer[2] == 0xFF && (_byteBuffer[3] & 0x1F) == 0x0C) {
        is7E = true;
      } else if ((_byteBuffer[0] & 0x1F) == 0x0C && _byteBuffer[1] == 0xFF && _byteBuffer[2] == 0x79 && _byteBuffer[3] == 0x02) {
        isMCU = true;
      } else if ((_byteBuffer[0] & 0x1F) == 0x18 && _byteBuffer[1] == 0xFF && _byteBuffer[2] == 0x01 && _byteBuffer[3] == 0xD5) {
        isMeter = true;
      }

      if (_byteBuffer.length > 4 && _byteBuffer[4] == 8) {
        headerSize = 5;
      }

      if (is7D && _byteBuffer.length >= headerSize + 8) {
        _processBmsVcu0(_byteBuffer.sublist(headerSize, headerSize + 8));
        _byteBuffer.removeRange(0, headerSize + 8);
        continue;
      }

      if (is7E && _byteBuffer.length >= headerSize + 8) {
        _processBmsVcu1(_byteBuffer.sublist(headerSize, headerSize + 8));
        _byteBuffer.removeRange(0, headerSize + 8);
        continue;
      }

      if (isMCU && _byteBuffer.length >= headerSize + 8) {
        _processMcuVcu0(_byteBuffer.sublist(headerSize, headerSize + 8));
        _byteBuffer.removeRange(0, headerSize + 8);
        continue;
      }

      if (isMeter && _byteBuffer.length >= headerSize + 8) {
        _processMeterVcu1(_byteBuffer.sublist(headerSize, headerSize + 8));
        _byteBuffer.removeRange(0, headerSize + 8);
        continue;
      }

      _byteBuffer.removeAt(0);
    }

    if (_byteBuffer.length > 256) _byteBuffer.clear();
  }

  void _parseAsciiLine(String line) {
    if (line.isEmpty) return;
    String clean = line.replaceAll(' ', '').toUpperCase();

    if (clean.contains('7D03') || clean.contains('8CFF7D03') || clean.contains('0CFF7D03')) {
      List<int> bytes = _extractHexBytes(clean);
      if (bytes.length >= 8) _processBmsVcu0(bytes.sublist(bytes.length - 8));
    } else if (clean.contains('7E03') || clean.contains('8CFF7E03') || clean.contains('0CFF7E03')) {
      List<int> bytes = _extractHexBytes(clean);
      if (bytes.length >= 8) _processBmsVcu1(bytes.sublist(bytes.length - 8));
    } else if (clean.contains('7902') || clean.contains('8CFF7902')) {
      List<int> bytes = _extractHexBytes(clean);
      if (bytes.length >= 8) _processMcuVcu0(bytes.sublist(bytes.length - 8));
    } else if (clean.contains('01D5') || clean.contains('98FF01D5')) {
      List<int> bytes = _extractHexBytes(clean);
      if (bytes.length >= 8) _processMeterVcu1(bytes.sublist(bytes.length - 8));
    }
  }

  List<int> _extractHexBytes(String hex) {
    List<int> res = [];
    int startIdx = hex.indexOf('8');
    String target = (startIdx != -1 && hex.length >= startIdx + 17) ? hex.substring(startIdx + 1) : hex;

    for (int i = 0; i < target.length - 1; i += 2) {
      int? v = int.tryParse(target.substring(i, i + 2), radix: 16);
      if (v != null) res.add(v);
    }
    return res;
  }

  void _processBmsVcu0(List<int> d) {
    if (d.length < 8) return;
    double parsedSoc = d[1] * 0.5;
    if (parsedSoc >= 1.0 && parsedSoc <= 100.0) {
      soc = parsedSoc;
      if (initialSoc == null && soc > 0) initialSoc = soc;
    }
    int rawHVolt = d[3] | (d[4] << 8);
    if (rawHVolt >= 2000 && rawHVolt <= 4500) maxCellVolt = rawHVolt * 0.001;

    int rawLVolt = d[6] | (d[7] << 8);
    if (rawLVolt >= 2000 && rawLVolt <= 4500) minCellVolt = rawLVolt * 0.001;
  }

  void _processBmsVcu1(List<int> d) {
    if (d.length < 8) return;
    if (d[1] >= 40 && d[1] <= 100) soh = d[1].toDouble();

    int rawVolt = d[2] | (d[3] << 8);
    if (rawVolt >= 200 && rawVolt <= 450) packVolt = rawVolt.toDouble();

    int rawCurr = d[4] | (d[5] << 8);
    if (rawCurr >= 500 && rawCurr <= 1500) {
      packCurr = (rawCurr - 1000).toDouble();
      packCurr = packCurr.clamp(-120.0, 150.0);
    }

    int rawTemp = d[6];
    if (rawTemp >= 20 && rawTemp <= 140) temp = (rawTemp - 40).toDouble();

    double pKw = (packVolt * packCurr) / 1000.0;
    if (pKw < -0.3) {
      chargeKw = pKw.abs().clamp(0.0, 60.0);
    } else {
      chargeKw = 0.0;
    }
  }

  void _processMcuVcu0(List<int> d) {
    if (d.length < 8) return;
    int rawSpd = d[4] | (d[5] << 8);
    motorRpm = (rawSpd - 12000).toDouble().clamp(0.0, 12000.0);
  }

  void _processMeterVcu1(List<int> d) {
    if (d.length < 8) return;
    speed = d[0].toDouble().clamp(0.0, 150.0);
  }

  @override
  Widget build(BuildContext context) {
    Color dynamicColor = _getEfficiencyColor(smoothedEfficiency);
    double ecoRange = soc * 2.3;
    double remainingKWh = 38.7 * (soc / 100.0);
    double bmsRange = remainingKWh * historicalEfficiency;
    double usedSoc = initialSoc != null ? math.max(0.0, initialSoc! - soc) : 0.0;
    double chargePercentPerHour = smoothedChargeKw > 0 ? (smoothedChargeKw / 0.387) : 0.0;
    double powerWatt = packVolt * packCurr;
    double powerKw = powerWatt / 1000.0;
    var eta = _calcChargeEta(soc, smoothedChargeKw > 0 ? smoothedChargeKw : chargeKw, temp);

    return Scaffold(
      backgroundColor: _getBgColor(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
          child: Column(
            children: [
              _buildHeader(dynamicColor),
              const SizedBox(height: 6),
              Expanded(
                child: _buildThemeBody(
                  dynamicColor: dynamicColor,
                  ecoRange: ecoRange,
                  bmsRange: bmsRange,
                  chargePercentPerHour: chargePercentPerHour,
                  powerWatt: powerWatt,
                  powerKw: powerKw,
                  eta: eta,
                ),
              ),
              const SizedBox(height: 8),
              _buildBidirectionalPowerBar(powerKw),
              const SizedBox(height: 8),
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
            style: const TextStyle(color: Color(0xFF78909C), fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1.5),
            children: [
              TextSpan(text: 'EV MONITOR', style: TextStyle(color: dynamicColor)),
            ],
          ),
        ),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(16)),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<DashboardTheme>(
                  value: currentTheme,
                  dropdownColor: const Color(0xFF161A22),
                  icon: Icon(Icons.palette_outlined, color: dynamicColor, size: 20),
                  onChanged: (newTheme) {
                    if (newTheme != null) setState(() => currentTheme = newTheme);
                  },
                  items: const [
                    DropdownMenuItem(value: DashboardTheme.originalNeon, child: Text('🟢 오리지널 네온', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold))),
                    DropdownMenuItem(value: DashboardTheme.teslaMinimal, child: Text('⚡ 테슬라 스타일', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold))),
                    DropdownMenuItem(value: DashboardTheme.bmwDynamic, child: Text('🔴 BMW M 스타일', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold))),
                    DropdownMenuItem(value: DashboardTheme.bydOcean, child: Text('🌊 BYD 오션 스타일', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold))),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            InkWell(
              onTap: () {
                if (isConnected) {
                  connection?.finish();
                } else {
                  _connectToEvLogger();
                }
              },
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: isConnected ? const Color(0x1400E676) : const Color(0x14FF5252),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: isConnected ? const Color(0x4000E676) : const Color(0x40FF5252)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
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
                    const SizedBox(width: 6),
                    Text(
                      isConnected ? 'EvLogger 연결됨' : connectionStatusText,
                      style: TextStyle(
                        color: isConnected ? const Color(0xFF00E676) : const Color(0xFFFF5252),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
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
    required double powerWatt,
    required double powerKw,
    required Map<String, dynamic> eta,
  }) {
    switch (currentTheme) {
      case DashboardTheme.originalNeon:
        return _buildOriginalNeonBody(dynamicColor, ecoRange, bmsRange, chargePercentPerHour, powerWatt, eta);
      case DashboardTheme.teslaMinimal:
        return _buildTeslaBody(dynamicColor, ecoRange, powerWatt, powerKw, eta);
      case DashboardTheme.bmwDynamic:
        return _buildBmwBody(dynamicColor, ecoRange, powerKw, eta);
      case DashboardTheme.bydOcean:
        return _buildBydBody(dynamicColor, ecoRange, bmsRange, chargePercentPerHour, eta);
    }
  }

  Widget _buildOriginalNeonBody(Color dynamicColor, double ecoRange, double bmsRange, double chargePercentPerHour, double powerWatt, Map<String, dynamic> eta) {
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

    Color powerValColor = powerWatt < 0 ? const Color(0xFF00FF88) : const Color(0xFFECEFF1);

    return Row(
      children: [
        Expanded(
          flex: 10,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildDataCard('연비 주행거리 (2.3km/%)', ecoRange.toStringAsFixed(1), 'km', const Color(0xFF00E676), const Color(0xFF00E676)),
              _buildDataCard('BMS 주행가능거리', bmsRange.toStringAsFixed(1), 'km', const Color(0xFFECEFF1), const Color(0xFF37474F)),
            ],
          ),
        ),
        Expanded(
          flex: 14,
          child: Center(
            child: SizedBox(
              width: 320,
              height: 320,
              child: CustomPaint(
                painter: HtmlExactGaugePainter(soc: soc, targetColor: dynamicColor),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('BATTERY', style: TextStyle(color: Color(0xFF78909C), fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 4.0)),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(soc.toStringAsFixed(1), style: TextStyle(color: dynamicColor, fontSize: 76, fontWeight: FontWeight.w900, height: 1.0)),
                          const Text('%', style: TextStyle(color: Color(0xFF00E676), fontSize: 32, fontWeight: FontWeight.bold)),
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
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildDataCard(
                '실시간 충전량',
                chargeKw.toStringAsFixed(1),
                'kW',
                const Color(0xFFFFB300),
                const Color(0xFFFFB300),
                subText: '(${chargePercentPerHour.toStringAsFixed(1)} %/h)',
                bottomInfo: etaText.isNotEmpty ? etaText : null,
              ),
              _buildDataCard(
                '실시간 배터리 전력',
                powerWatt.abs().toStringAsFixed(0),
                'W',
                powerValColor,
                const Color(0xFF00E5FF),
                subText: '${packVolt.toStringAsFixed(0)}V / ${packCurr.toStringAsFixed(1)}A',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTeslaBody(Color dynamicColor, double ecoRange, double powerWatt, double powerKw, Map<String, dynamic> eta) {
    String etaText = chargeKw > 0.3 ? (eta['isPreheating'] ? '[예열] 완충 약 ${eta['to100']}분' : (soc < 80 ? '80% 약 ${eta['to80']}분 | 완충 약 ${eta['to100']}분' : '완충 약 ${eta['to100']}분')) : '';
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          decoration: BoxDecoration(color: const Color(0xFF222226), borderRadius: BorderRadius.circular(18)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('BATTERY LEVEL', style: TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold)),
                Text('${soc.toStringAsFixed(0)}%', style: TextStyle(color: dynamicColor, fontSize: 56, fontWeight: FontWeight.w900)),
              ]),
              if (etaText.isNotEmpty)
                Text(etaText, style: const TextStyle(color: Color(0xFFFFB300), fontSize: 16, fontWeight: FontWeight.bold)),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                const Text('ESTIMATED RANGE', style: TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold)),
                Text('${ecoRange.toStringAsFixed(0)} km', style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 48, fontWeight: FontWeight.bold)),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: (soc / 100).clamp(0.0, 1.0),
            minHeight: 14,
            backgroundColor: const Color(0xFF222226),
            valueColor: AlwaysStoppedAnimation<Color>(dynamicColor),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildDataCard('실시간 출력/충전', '${powerKw.toStringAsFixed(1)}', 'kW', dynamicColor, dynamicColor)),
              const SizedBox(width: 14),
              Expanded(
                child: _buildDataCard(
                  '배터리 전력',
                  powerWatt.abs().toStringAsFixed(0),
                  'W',
                  Colors.white,
                  const Color(0xFF38BDF8),
                  subText: '${packVolt.toStringAsFixed(0)}V / ${packCurr.toStringAsFixed(1)}A',
                ),
              ),
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
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF141A29),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFE9271D), width: 3),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('//M POWER (kW)', style: TextStyle(color: Color(0xFFE9271D), fontSize: 16, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                const SizedBox(height: 6),
                Text(powerKw.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 56, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                Text('${(packVolt * packCurr).abs().toStringAsFixed(0)} W (${packVolt.toStringAsFixed(0)}V / ${packCurr.toStringAsFixed(1)}A)', style: const TextStyle(color: Colors.white54, fontSize: 14)),
              ],
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF141A29),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF0066B1), width: 3),
            ),
            child: Column(
              mainAxisAlignment: CenterAlignment.center,
              children: [
                const Text('BATTERY SOC', style: TextStyle(color: Color(0xFF0066B1), fontSize: 16, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                const SizedBox(height: 6),
                Text('${soc.toStringAsFixed(0)}%', style: TextStyle(color: dynamicColor, fontSize: 56, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                Text('EST. ${ecoRange.toStringAsFixed(0)} km', style: const TextStyle(color: Color(0xFF00FF88), fontSize: 18, fontWeight: FontWeight.bold)),
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
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF06213F),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('BLADE BATTERY SOC', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 14, letterSpacing: 1.2, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('${soc.toStringAsFixed(1)} %', style: TextStyle(color: dynamicColor, fontSize: 50, fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: (soc / 100).clamp(0.0, 1.0),
                  backgroundColor: Colors.black38,
                  valueColor: AlwaysStoppedAnimation<Color>(dynamicColor),
                ),
                const SizedBox(height: 10),
                Text('주행 가능: ${ecoRange.toStringAsFixed(1)} km', style: const TextStyle(color: Colors.white70, fontSize: 16)),
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
              const SizedBox(height: 10),
              Expanded(child: _buildDataCard('BMS 주행가능거리', bmsRange.toStringAsFixed(1), 'km', Colors.white, const Color(0xFF37474F))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBidirectionalPowerBar(double powerKw) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1116),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF222733), width: 1.5),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('◀ 회생제동 (REGEN)', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 0.5)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '실시간 파워: ${powerKw.toStringAsFixed(1)} kW',
                  style: TextStyle(
                    color: powerKw < 0 ? const Color(0xFF00FF88) : (powerKw > 30 ? const Color(0xFFFF3366) : const Color(0xFFFFB800)),
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const Text('가속 출력 (POWER) ▶', style: TextStyle(color: Color(0xFFFF5252), fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 0.5)),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 24,
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
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1116),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1C212C)),
      ),
      child: Row(
        children: [
          _buildSubItem('운행 시간', _formatDuration(totalSeconds), const Color(0xFF00E5FF)),
          _buildSubDivider(),
          _buildSubItem('배터리 건강(SOH)', '${soh.toStringAsFixed(0)} %', const Color(0xFF00E5FF)),
          _buildSubDivider(),
          _buildSubItem('배터리 사용량', '${usedSoc.toStringAsFixed(1)} %', const Color(0xFFFF5252)),
          _buildSubDivider(),
          _buildSubItem('배터리온도', '${temp.toStringAsFixed(1)} °C', const Color(0xFF00E5FF)),
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
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF13161C), Color(0xFF0E1015)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF222733)),
      ),
      child: Stack(
        children: [
          Positioned(
            left: -20,
            top: -16,
            bottom: -16,
            child: Container(width: 6, color: barColor),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label, style: const TextStyle(color: Color(0xFF90A4AE), fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(value, style: TextStyle(color: valColor, fontSize: 38, fontWeight: FontWeight.w900)),
                  const SizedBox(width: 6),
                  Text(unit, style: const TextStyle(color: Color(0xFF78909C), fontSize: 16, fontWeight: FontWeight.w600)),
                  if (subText != null) ...[
                    const Spacer(),
                    Text(subText, style: const TextStyle(color: Color(0xFF78909C), fontSize: 15, fontWeight: FontWeight.w600)),
                  ],
                ],
              ),
              if (bottomInfo != null) ...[
                const SizedBox(height: 6),
                Text(bottomInfo, style: const TextStyle(color: Color(0xFF00FF88), fontSize: 13, fontWeight: FontWeight.bold)),
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
          Text(label, style: const TextStyle(color: Color(0xFF78909C), fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(color: valColor, fontSize: 22, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  Widget _buildSubDivider() {
    return Container(width: 1.5, height: 32, color: const Color(0xFF1C212C));
  }
}

class HtmlExactGaugePainter extends CustomPainter {
  final double soc;
  final Color targetColor;
  HtmlExactGaugePainter({required this.soc, required this.targetColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 30) / 2;

    final bgPaint = Paint()
      ..color = const Color(0xFF161A22)
      ..strokeWidth = 22
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, bgPaint);

    final sweepAngle = 2 * math.pi * (soc / 100.0).clamp(0.0, 1.0);
    final rect = Rect.fromCircle(center: center, radius: radius);

    final progressPaint = Paint()
      ..color = targetColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 22
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
    final rrect = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width, size.height), const Radius.circular(8));

    final bgPaint = Paint()..color = const Color(0xFF161A22);
    canvas.drawRRect(rrect, bgPaint);

    final centerLinePaint = Paint()
      ..color = Colors.white54
      ..strokeWidth = 3;
    canvas.drawLine(Offset(center, 0), Offset(center, size.height), centerLinePaint);

    if (powerKw < 0) {
      double regenRatio = (powerKw.abs() / 25.0).clamp(0.0, 1.0);
      double barWidth = center * regenRatio;
      final regenPaint = Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFF00E5FF), Color(0xFF00FF88)],
        ).createShader(Rect.fromLTWH(center - barWidth, 0, barWidth, size.height));
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(center - barWidth, 0, barWidth, size.height), const Radius.circular(8)),
        regenPaint,
      );
    } else if (powerKw > 0) {
      double powerRatio = (powerKw / 60.0).clamp(0.0, 1.0);
      double barWidth = (size.width - center) * powerRatio;
      Color barColor = powerKw > 35 ? const Color(0xFFFF3366) : const Color(0xFFFFB800);
      final powerPaint = Paint()..color = barColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(center, 0, barWidth, size.height), const Radius.circular(8)),
        powerPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant BidirectionalPowerPainter oldDelegate) => oldDelegate.powerKw != powerKw;
}
