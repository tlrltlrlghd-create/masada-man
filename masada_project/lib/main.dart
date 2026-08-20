import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const MaterialApp(
      home: MasadaDashboardApp(),
      debugShowCheckedModeBanner: false,
    ));

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

  // CAN 실시간 데이터
  double soc = 78.5; // 기본 프리뷰용 초기값 (연결 시 실시간 덮어씀)
  double packVolt = 345.0;
  double packCurr = -12.4;
  double maxCellVolt = 3.421;
  double minCellVolt = 3.408;
  int maxTemp = 28;
  int minTemp = 24;
  double estDistance = 180.5; // 2.3km/% 기준
  double bmsDistance = 175.0;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
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

  void _onDataReceived(Uint8List rawBytes) {
    if (rawBytes.length >= 8) {
      ByteData view = ByteData.sublistView(rawBytes);
      setState(() {
        soc = (rawBytes[1] * 0.5).clamp(0.0, 100.0);
        packVolt = view.getUint16(2, Endian.little).toDouble();
        packCurr = (view.getUint16(4, Endian.little) - 1000).toDouble();
        maxCellVolt = view.getUint16(3, Endian.little) * 0.001;
        minCellVolt = view.getUint16(6, Endian.little) * 0.001;
        maxTemp = rawBytes[6] - 40;
        minTemp = rawBytes[7] - 40;
        estDistance = soc * 2.3;
        bmsDistance = soc * 2.2;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _getThemeBackground(),
      appBar: _buildTopAppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: _buildThemeBody(),
        ),
      ),
    );
  }

  Color _getThemeBackground() {
    switch (currentTheme) {
      case DashboardTheme.originalNeon:
        return const Color(0xFF070B12);
      case DashboardTheme.teslaMinimal:
        return const Color(0xFF18181B);
      case DashboardTheme.bmwDynamic:
        return const Color(0xFF0B0D13);
      case DashboardTheme.bydOcean:
        return const Color(0xFF031326);
    }
  }

  PreferredSizeWidget _buildTopAppBar() {
    Color barColor;
    Color accentColor;
    String brandName;

    switch (currentTheme) {
      case DashboardTheme.originalNeon:
        barColor = const Color(0xFF0F172A);
        accentColor = const Color(0xFF00FF9D);
        brandName = 'MASADA VAN EV';
        break;
      case DashboardTheme.teslaMinimal:
        barColor = const Color(0xFF27272A);
        accentColor = Colors.white;
        brandName = 'MODEL MASADA';
        break;
      case DashboardTheme.bmwDynamic:
        barColor = const Color(0xFF141A29);
        accentColor = const Color(0xFF0066B1);
        brandName = 'MASADA //M POWER';
        break;
      case DashboardTheme.bydOcean:
        barColor = const Color(0xFF06213F);
        accentColor = const Color(0xFF00E5FF);
        brandName = 'BYD OCEAN MASADA';
        break;
    }

    return AppBar(
      backgroundColor: barColor,
      elevation: 0,
      title: Row(
        children: [
          Text(brandName, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1.2)),
        ],
      ),
      actions: [
        // 테마 선택 드롭다운
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<DashboardTheme>(
              value: currentTheme,
              dropdownColor: barColor,
              icon: Icon(Icons.palette_outlined, color: accentColor, size: 20),
              onChanged: (newTheme) {
                if (newTheme != null) setState(() => currentTheme = newTheme);
              },
              items: const [
                DropdownMenuItem(value: DashboardTheme.originalNeon, child: Text('🟢 오리지널 네온', style: TextStyle(color: Colors.white, fontSize: 13))),
                DropdownMenuItem(value: DashboardTheme.teslaMinimal, child: Text('⚡ 테슬라 미니멀', style: TextStyle(color: Colors.white, fontSize: 13))),
                DropdownMenuItem(value: DashboardTheme.bmwDynamic, child: Text('🔴 BMW M 스포츠', style: TextStyle(color: Colors.white, fontSize: 13))),
                DropdownMenuItem(value: DashboardTheme.bydOcean, child: Text('🌊 BYD 오션 블루', style: TextStyle(color: Colors.white, fontSize: 13))),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 블루투스 연결 버튼
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: isConnected ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
              foregroundColor: isConnected ? Colors.greenAccent : Colors.redAccent,
              side: BorderSide(color: isConnected ? Colors.greenAccent : Colors.redAccent, width: 1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              elevation: 0,
            ),
            onPressed: isConnected ? () => connection?.finish() : _connectToEvLogger,
            icon: Icon(isConnected ? Icons.bluetooth_connected : Icons.bluetooth, size: 16),
            label: Text(isConnected ? '연결됨' : (isConnecting ? '연결중..' : '연결'), style: const TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }

  Widget _buildThemeBody() {
    switch (currentTheme) {
      case DashboardTheme.originalNeon:
        return _buildOriginalNeonUI();
      case DashboardTheme.teslaMinimal:
        return _buildTeslaUI();
      case DashboardTheme.bmwDynamic:
        return _buildBmwUI();
      case DashboardTheme.bydOcean:
        return _buildBydUI();
    }
  }

  // ================= 1. 기존 스크린샷 스타일 (오리지널 네온) =================
  Widget _buildOriginalNeonUI() {
    double powerKw = (packVolt * packCurr) / 1000.0;
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    _buildBox('연비 주행거리 (2.3km/%)', '${estDistance.toStringAsFixed(1)} km', const Color(0xFF00FF9D), const Color(0xFF131B2E)),
                    const SizedBox(height: 12),
                    _buildBox('BMS 주행가능거리', '${bmsDistance.toStringAsFixed(0)} km', Colors.white, const Color(0xFF131B2E)),
                  ],
                ),
              ),
              Expanded(
                flex: 4,
                child: Center(
                  child: SizedBox(
                    width: 170,
                    height: 170,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          value: (soc / 100).clamp(0.0, 1.0),
                          strokeWidth: 14,
                          backgroundColor: const Color(0xFF131B2E),
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00FF9D)),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('BATTERY', style: TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 1.5)),
                            const SizedBox(height: 4),
                            Text('${soc.toStringAsFixed(1)}%', style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
                          ],
                        )
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    _buildBox('실시간 충전/출력', '${powerKw.abs().toStringAsFixed(1)} kW', Colors.amberAccent, const Color(0xFF131B2E)),
                    const SizedBox(height: 12),
                    _buildBox('팩 전압 / 전류', '${packVolt.toStringAsFixed(0)}V / ${packCurr.toStringAsFixed(1)}A', Colors.lightBlueAccent, const Color(0xFF131B2E)),
                  ],
                ),
              ),
            ],
          ),
        ),
        _buildBottomBar(const Color(0xFF131B2E), const Color(0xFF00FF9D)),
      ],
    );
  }

  // ================= 2. 테슬라 스타일 (미니멀 & 클린 블랙/화이트) =================
  Widget _buildTeslaUI() {
    double powerKw = (packVolt * packCurr) / 1000.0;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: const Color(0xFF27272A), borderRadius: BorderRadius.circular(16)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('BATTERY LEVEL', style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600)),
                  Text('${soc.toStringAsFixed(0)}%', style: const TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.w900)),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('ESTIMATED RANGE', style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600)),
                  Text('${estDistance.toStringAsFixed(0)} km', style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 36, fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: (soc / 100).clamp(0.0, 1.0),
            minHeight: 12,
            backgroundColor: const Color(0xFF27272A),
            valueColor: AlwaysStoppedAnimation<Color>(soc > 20 ? const Color(0xFF22C55E) : Colors.redAccent),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 2.2,
            children: [
              _buildBox('POWER OUTPUT', '${powerKw.toStringAsFixed(2)} kW', Colors.white, const Color(0xFF27272A)),
              _buildBox('PACK VOLTAGE', '${packVolt.toStringAsFixed(1)} V', Colors.white, const Color(0xFF27272A)),
              _buildBox('PACK CURRENT', '${packCurr.toStringAsFixed(1)} A', Colors.white, const Color(0xFF27272A)),
              _buildBox('MAX/MIN CELL', '${maxCellVolt.toStringAsFixed(3)}V / ${minCellVolt.toStringAsFixed(3)}V', const Color(0xFF38BDF8), const Color(0xFF27272A)),
            ],
          ),
        ),
        _buildBottomBar(const Color(0xFF27272A), const Color(0xFF38BDF8)),
      ],
    );
  }

  // ================= 3. BMW //M 스타일 (다이내믹 앵글 & 레드/블루) =================
  Widget _buildBmwUI() {
    double powerKw = (packVolt * packCurr) / 1000.0;
    return Column(
      children: [
        Row(
          children: [
            Container(width: 6, height: 40, color: const Color(0xFF0066B1)),
            const SizedBox(width: 4),
            Container(width: 6, height: 40, color: const Color(0xFF001E50)),
            const SizedBox(width: 4),
            Container(width: 6, height: 40, color: const Color(0xFFE9271D)),
            const SizedBox(width: 12),
            const Text('SPORT //M DISPLAY', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141A29),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE9271D), width: 1.5),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('POWER (kW)', style: TextStyle(color: Color(0xFFE9271D), fontSize: 12, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(powerKw.toStringAsFixed(1), style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                      Text('${packVolt.toStringAsFixed(0)}V / ${packCurr.toStringAsFixed(0)}A', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141A29),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF0066B1), width: 1.5),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('BATTERY SOC', style: TextStyle(color: Color(0xFF0066B1), fontSize: 12, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('${soc.toStringAsFixed(0)}%', style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                      Text('EST. ${estDistance.toStringAsFixed(0)} km', style: const TextStyle(color: Color(0xFF00FF9D), fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildBottomBar(const Color(0xFF141A29), const Color(0xFFE9271D)),
      ],
    );
  }

  // ================= 4. BYD 스타일 (오션 블루 & 하이테크 인포) =================
  Widget _buildBydUI() {
    double powerKw = (packVolt * packCurr) / 1000.0;
    return Column(
      children: [
        Expanded(
          child: Row(
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
                      const Text('BLADE BATTERY SOC', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 12, letterSpacing: 1.2)),
                      const SizedBox(height: 8),
                      Text('${soc.toStringAsFixed(1)} %', style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: (soc / 100).clamp(0.0, 1.0),
                        backgroundColor: Colors.black38,
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                      ),
                      const SizedBox(height: 12),
                      Text('주행 가능: ${estDistance.toStringAsFixed(1)} km', style: const TextStyle(color: Colors.white70, fontSize: 13)),
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
                      child: Row(
                        children: [
                          Expanded(child: _buildBox('충/방전 파워', '${powerKw.toStringAsFixed(1)} kW', const Color(0xFF00E5FF), const Color(0xFF06213F))),
                          const SizedBox(width: 8),
                          Expanded(child: _buildBox('시스템 전압', '${packVolt.toStringAsFixed(0)} V', Colors.white, const Color(0xFF06213F))),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(child: _buildBox('셀 편차(최대/최소)', '${maxCellVolt.toStringAsFixed(3)}V\n${minCellVolt.toStringAsFixed(3)}V', const Color(0xFF00FF9D), const Color(0xFF06213F))),
                          const SizedBox(width: 8),
                          Expanded(child: _buildBox('배터리 팩 온도', 'MAX $maxTemp ℃\nMIN $minTemp ℃', Colors.amberAccent, const Color(0xFF06213F))),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildBottomBar(const Color(0xFF06213F), const Color(0xFF00E5FF)),
      ],
    );
  }

  // 공통 카드 컴포넌트
  Widget _buildBox(String title, String value, Color valColor, Color bgColor) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: const TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(color: valColor, fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // 공통 하단 퀵 인포 바
  Widget _buildBottomBar(Color bgColor, Color accentColor) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildBottomItem('최고 셀', '${maxCellVolt.toStringAsFixed(3)} V', accentColor),
          Container(width: 1, height: 20, color: Colors.white12),
          _buildBottomItem('최저 셀', '${minCellVolt.toStringAsFixed(3)} V', accentColor),
          Container(width: 1, height: 20, color: Colors.white12),
          _buildBottomItem('배터리 온도', '$maxTemp℃ / $minTemp℃', Colors.redAccent),
          Container(width: 1, height: 20, color: Colors.white12),
          _buildBottomItem('팩 전류', '${packCurr.toStringAsFixed(1)} A', Colors.amberAccent),
        ],
      ),
    );
  }

  Widget _buildBottomItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
