import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const MaterialApp(home: MasadaDashboard(), debugShowCheckedModeBanner: false));

class MasadaDashboard extends StatefulWidget {
  const MasadaDashboard({super.key});
  @override
  State<MasadaDashboard> createState() => _MasadaDashboardState();
}

class _MasadaDashboardState extends State<MasadaDashboard> {
  BluetoothConnection? connection;
  bool isConnecting = false;
  bool isConnected = false;
  double soc = 0.0;
  double packVolt = 0.0;
  double packCurr = 0.0;
  double maxCellVolt = 0.0;
  double minCellVolt = 0.0;
  int maxTemp = 0;
  int minTemp = 0;

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
        soc = rawBytes[1] * 0.5;
        maxCellVolt = view.getUint16(3, Endian.little) * 0.001;
        minCellVolt = view.getUint16(6, Endian.little) * 0.001;
        packVolt = view.getUint16(2, Endian.little).toDouble();
        packCurr = (view.getUint16(4, Endian.little) - 1000).toDouble();
        maxTemp = rawBytes[6] - 40;
        minTemp = rawBytes[7] - 40;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('MASADA EV MONITOR', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          IconButton(
            icon: Icon(isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                color: isConnected ? Colors.greenAccent : Colors.redAccent),
            onPressed: isConnected ? () => connection?.finish() : _connectToEvLogger,
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                _buildCard('SOC (배터리)', '${soc.toStringAsFixed(1)} %', Colors.tealAccent, flex: 2),
                const SizedBox(width: 12),
                _buildCard('현재 전력', '${(packVolt * packCurr / 1000).toStringAsFixed(2)} kW', Colors.orangeAccent, flex: 2),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildCard('팩 전압', '${packVolt.toStringAsFixed(0)} V', Colors.blueAccent),
                const SizedBox(width: 12),
                _buildCard('팩 전류', '${packCurr.toStringAsFixed(1)} A', Colors.amberAccent),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildCard('최고/최저 셀', '${maxCellVolt.toStringAsFixed(3)}V / ${minCellVolt.toStringAsFixed(3)}V', Colors.cyanAccent),
                const SizedBox(width: 12),
                _buildCard('배터리 온도', '$maxTemp ℃ / $minTemp ℃', Colors.redAccent),
              ],
            ),
            const Spacer(),
            if (!isConnected)
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: isConnecting ? null : _connectToEvLogger,
                icon: const Icon(Icons.refresh),
                label: Text(isConnecting ? '연결 시도 중...' : 'EvLogger 연결하기'),
              )
          ],
        ),
      ),
    );
  }

  Widget _buildCard(String title, String value, Color accentColor, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accentColor.withOpacity(0.3), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(color: Colors.grey[400], fontSize: 13)),
            const SizedBox(height: 8),
            Text(value, style: TextStyle(color: accentColor, fontSize: 22, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
