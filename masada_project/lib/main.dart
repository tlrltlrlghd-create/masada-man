import 'dart:async';
import 'dart:convert';
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
  final double realSpeedKmh;
  _DrivingSample(this.powerKw, this.realSpeedKmh);
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _isCampingMode = false;
  static const double _batteryTotalKwh = 38.7;

  BluetoothConnection? _connection;
  bool _isConnected = false;
  bool _isConnecting = false;
  final List<int> _rxBuffer = [];
  String _asciiBuffer = "";
  Timer? _autoConnectTimer;
  Timer? _heartbeatTimer;

  // 실시간 차량 데이터
  double _soc = 62.0;
  double _voltage = 315.0;
  double _current = 0.0;
  double _powerKw = 0.0;
  double _chargePowerKw = 0.0;
  double _batteryTemp = 28.0;
  int _soh = 94;
  double _bmsDistance = 128.6;

  bool _isWaterAlarm = false;
  double _realVehicleSpeedKmh = 0.0;
  double _accumulatedRealTripKm = 0.0;
  double _lastTripOdoKm = -1.0;

  String _currentGear = "D";
  int _neutralDurationSeconds = 0;

  int _cellMaxMv = 3315;
  int _cellMinMv = 3300;
  int _cellDeltaMv = 15;

  // 💡 [1분 실시간 주행 효율 샘플 버퍼]
  final List<_DrivingSample> _recent1MinSamples = [];
  double _recent1MinEfficiency = 5.7;
  int _efficiencyScore = 50;

  // 💡 [이번 주행(D, R) 순수 누적 에너지 및 거리]
  double _pureDriveEnergyKwh = 0.0;
  double _pureDriveDistanceKm = 0.0;
  double _pureDriveTripEfficiency = 5.7;

  // 누적 통계
  double _accumulatedRegenKwh = 0.0;
  double _driveEnergyKwh = 0.0;
  double _hvacEnergyKwh = 0.0;
  int _drivingSeconds = 0;
  int _loadSampleCount = 0;
  double _accumulatedLoadPct = 0.0;
  Timer? _drivingTimer;

  @override
  void initState() {
    super.initState();
    _startDrivingTimer();
    _connectToLogger();
    _autoConnectTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
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

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_isConnected && _connection != null) {
        try {
          _connection!.output.add(Uint8List.fromList([0xAA, 0x55, 0x01, 0x00, 0x00, 0x00]));
          _connection!.output.add(ascii.encode("AT\r\n"));
          _connection!.output.allSent;
        } catch (_) {}
      }
    });
  }

  Future<void> _connectToLogger() async {
    if (_isConnected || _isConnecting) return;
    if (mounted) setState(() => _isConnecting = true);

    try {
      if (_connection != null) {
        try {
          await _connection!.close();
          _connection!.dispose();
        } catch (_) {}
        _connection = null;
        await Future.delayed(const Duration(milliseconds: 300));
      }

      List<BluetoothDevice> devices = await FlutterBluetoothSerial.instance.getBondedDevices();
      BluetoothDevice? targetDevice;

      for (var d in devices) {
        String name = (d.name ?? '').toUpperCase();
        if (name.contains('F0D6') || name.contains('OBD') || name.contains('EV') || name.contains('MASADA') || name.contains('LOGGER')) {
          targetDevice = d;
          break;
        }
      }

      targetDevice ??= devices.isNotEmpty ? devices.first : null;

      if (targetDevice != null) {
        _connection = await BluetoothConnection.toAddress(targetDevice.address);
        _startHeartbeat();

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
            if (mounted) setState(() { _isConnected = false; _isConnecting = false; });
          },
          onError: (error) {
            _heartbeatTimer?.cancel();
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

  void _processData(Uint8List data) {
    _rxBuffer.addAll(data);
    _asciiBuffer += String.fromCharCodes(data);

    if (_asciiBuffer.contains('\r') || _asciiBuffer.contains('\n')) {
      List<String> lines = _asciiBuffer.split(RegExp(r'[\r\n]+'));
      _asciiBuffer = lines.last;
      for (int i = 0; i < lines.length - 1; i++) {
        _parseAsciiLine(lines[i].trim());
      }
    }

    while (_rxBuffer.length >= 12) {
      bool matched = false;
      for (int i = 0; i <= _rxBuffer.length - 12; i++) {
        int idBig = ((_rxBuffer[i] << 24) | (_rxBuffer[i + 1] << 16) | (_rxBuffer[i + 2] << 8) | _rxBuffer[i + 3]) & 0x1FFFFFFF;
        int idLittle = ((_rxBuffer[i + 3] << 24) | (_rxBuffer[i + 2] << 16) | (_rxBuffer[i + 1] << 8) | _rxBuffer[i]) & 0x1FFFFFFF;
        
        List<int> payload = _rxBuffer.sublist(i + 4, i + 12);

        if (_dispatchCanMessage(idBig, payload) || _dispatchCanMessage(idLittle, payload)) {
          _rxBuffer.removeRange(0, i + 12);
          matched = true;
          break;
        }
      }
      if (!matched) {
        if (_rxBuffer.length > 256) _rxBuffer.removeRange(0, 128);
        break;
      }
    }
  }

  void _parseAsciiLine(String line) {
    String clean = line.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    if (clean.length < 24) return;

    try {
      int id = int.parse(clean.substring(0, 8), radix: 16) & 0x1FFFFFFF;
      List<int> payload = _hexToBytes(clean.substring(8, 24));
      _dispatchCanMessage(id, payload);
    } catch (_) {}
  }

  List<int> _hexToBytes(String hex) {
    List<int> bytes = [];
    for (int i = 0; i < hex.length - 1; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  bool _dispatchCanMessage(int id, List<int> d) {
    if (d.length < 8) return false;

    // 1. BMS_VCU_0 (BO_ 2365553923 = 0x0CFF7D03)
    if (id == 0x0CFF7D03) {
      int rawSoc = d[1];
      if (rawSoc > 0 && rawSoc <= 200) {
        _soc = rawSoc * 0.5;
      }
      int hVolt = (d[4] << 8) | d[3];
      int lVolt = (d[7] << 8) | d[6];
      if (hVolt >= 2500 && hVolt <= 4200) _cellMaxMv = hVolt;
      if (lVolt >= 2500 && lVolt <= 4200) _cellMinMv = lVolt;
      _cellDeltaMv = (_cellMaxMv - _cellMinMv).clamp(0, 300);
      if (mounted) setState(() {});
      return true;
    }

    // 2. BMS_VCU_1 (BO_ 2365554179 = 0x0CFF7E03)
    if (id == 0x0CFF7E03) {
      int rawSoh = d[1];
      if (rawSoh >= 50 && rawSoh <= 100) _soh = rawSoh;

      int rawVolt = (d[3] << 8) | d[2];
      if (rawVolt >= 200 && rawVolt <= 500) {
        _voltage = rawVolt.toDouble();
      }

      int rawCurr = (d[5] << 8) | d[4];
      if (rawCurr >= 0 && rawCurr <= 65535) {
        double calcCurr = (rawCurr - 1000).toDouble();
        if (calcCurr.abs() <= 300.0) _current = calcCurr;
      }

      int rawTemp = d[6];
      if (rawTemp >= 40 && rawTemp <= 140) {
        _batteryTemp = (rawTemp - 40).toDouble();
      }

      double calcPower = (_voltage * _current) / 1000.0;
      if (calcPower.abs() > 70.0) calcPower = 0.0;
      _powerKw = calcPower;

      if (_current < -0.5) {
        _chargePowerKw = calcPower.abs();
      } else {
        _chargePowerKw = 0.0;
      }
      if (mounted) setState(() {});
      return true;
    }

    // 3. VCU_Meter (BO_ 2566904833 = 0x19014801 / 0x18FF50E5 / 0x18FFDC01)
    if (id == 0x19014801 || id == 0x18FF50E5 || id == 0x18FFDC01 || id == 0x09014801) {
      int rawGear = (d[4] >> 2) & 0x03;
      if (rawGear == 0) {
        _currentGear = "N";
      } else if (rawGear == 1) {
        _currentGear = "D";
      } else if (rawGear == 2) {
        _currentGear = "R";
      } else if (rawGear == 3) {
        _currentGear = "P";
      }

      if (_currentGear == "D" && _isCampingMode) {
        _isCampingMode = false;
        _neutralDurationSeconds = 0;
      }
      if (mounted) setState(() {});
      return true;
    }

    // 4. Meter_VCU_1 (BO_ 2566839509 = 0x190048D5 / 0x18FEDCD5)
    if (id == 0x190048D5 || id == 0x18FEDCD5 || id == 0x090048D5) {
      _realVehicleSpeedKmh = d[0].toDouble();

      int rawDist = (d[4] << 24) | (d[3] << 16) | (d[2] << 8) | d[1];
      if (rawDist > 1000 && rawDist < 2000000) {
        double odoKm = rawDist.toDouble();
        if (_lastTripOdoKm >= 0 && odoKm >= _lastTripOdoKm && (odoKm - _lastTripOdoKm) < 5.0) {
          _accumulatedRealTripKm += (odoKm - _lastTripOdoKm);
        }
        _lastTripOdoKm = odoKm;
      }
      if (mounted) setState(() {});
      return true;
    }

    // 5. BMS_VCU_4 (BO_ 2365554947 = 0x0CFF8103)
    if (id == 0x0CFF8103) {
      _isWaterAlarm = (d[6] & 0x01) != 0;
      if (mounted) setState(() {});
      return true;
    }

    return false;
  }

  void _startDrivingTimer() {
    _drivingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _drivingSeconds++;

          // N단 60초 지속 시 자동 캠핑모드
          if (_currentGear == "N" || (_realVehicleSpeedKmh < 0.5 && _powerKw.abs() < 0.3)) {
            _neutralDurationSeconds++;
            if (_neutralDurationSeconds >= 60 && !_isCampingMode) {
              _isCampingMode = true;
            }
          } else {
            _neutralDurationSeconds = 0;
            if (_isCampingMode && _realVehicleSpeedKmh > 1.0) {
              _isCampingMode = false;
            }
          }

          if (!_isCampingMode && _isConnected) {
            double currentSpeed = _realVehicleSpeedKmh > 0.5 ? _realVehicleSpeedKmh : (_powerKw > 1.0 ? (_powerKw * 4.5).clamp(10.0, 100.0) : 0.0);
            double secondDistKm = currentSpeed / 3600.0;

            if (_current < -0.5 && _chargePowerKw > 0.1) {
              _accumulatedRegenKwh += (_chargePowerKw / 3600.0);
            }
            if (_powerKw > 1.0) {
              _driveEnergyKwh += (_powerKw / 3600.0);
              double liveLoad = (_powerKw / 60.0 * 100.0).clamp(0.0, 100.0);
              _accumulatedLoadPct += liveLoad;
              _loadSampleCount++;
            } else if (_powerKw > 0.05) {
              _hvacEnergyKwh += (_powerKw / 3600.0);
            }

            if (_realVehicleSpeedKmh <= 0.0 && _powerKw > 1.0) {
              _accumulatedRealTripKm += secondDistKm;
            } else if (_realVehicleSpeedKmh > 0.0) {
              _accumulatedRealTripKm += secondDistKm;
            }

            // 💡 [D, R 기어 상태일 때만 순수 주행 전비 연산에 누적]
            if (_currentGear == "D" || _currentGear == "R") {
              if (_powerKw > 0.1) {
                _pureDriveEnergyKwh += (_powerKw / 3600.0);
              }
              _pureDriveDistanceKm += secondDistKm;

              if (_pureDriveEnergyKwh > 0.02 && _pureDriveDistanceKm > 0.05) {
                _pureDriveTripEfficiency = (_pureDriveDistanceKm / _pureDriveEnergyKwh).clamp(2.0, 12.0);
              }
            }

            _update1MinEfficiencyAndBmsDistance();
          }
        });
      }
    });
  }

  // 💡 [1분 실시간 효율 및 복합 전비 BMS 주행가능거리 연산]
  void _update1MinEfficiencyAndBmsDistance() {
    double speed = _realVehicleSpeedKmh > 0.5 ? _realVehicleSpeedKmh : (_powerKw > 1.0 ? (_powerKw * 4.5).clamp(10.0, 100.0) : 0.0);

    // 1분(60초) 샘플링
    _recent1MinSamples.add(_DrivingSample(_powerKw, speed));
    if (_recent1MinSamples.length > 60) {
      _recent1MinSamples.removeAt(0);
    }

    if (_recent1MinSamples.length >= 10) {
      double totalNetKwh = 0.0;
      double totalDistanceKm = 0.0;
      for (var s in _recent1MinSamples) {
        totalNetKwh += (s.powerKw / 3600.0);
        totalDistanceKm += (s.realSpeedKmh / 3600.0);
      }
      if (totalNetKwh > 0.005 && totalDistanceKm > 0.01) {
        _recent1MinEfficiency = (totalDistanceKm / totalNetKwh).clamp(2.0, 10.0);
      }
    }

    double rawScore = ((_recent1MinEfficiency - 3.7) / (7.7 - 3.7)) * 100.0;
    _efficiencyScore = rawScore.clamp(0.0, 100.0).round();

    // 💡 [수정 요청 1]: 30%는 배터리 1% * 2.4km, 나머지 70%는 이번 순수 주행 전비(D, R)
    double baseDistance30Pct = (_soc * 2.4) * 0.3;
    double currentRemainKwh = (_batteryTotalKwh * (_soh / 100.0)) * (_soc / 100.0);
    double dynamicDistance70Pct = (currentRemainKwh * _pureDriveTripEfficiency) * 0.7;

    _bmsDistance = double.parse((baseDistance30Pct + dynamicDistance70Pct).toStringAsFixed(1));
  }

  String _calculateTimeToSoc(double targetSoc) {
    if (_chargePowerKw < 0.5) return "--";

    if (targetSoc == 80.0) {
      if (_soc >= 80.0) return "완료";
      double neededKwh = _batteryTotalKwh * ((80.0 - _soc) / 100.0);
      int minutes = ((neededKwh / _chargePowerKw) * 60).round();
      return "${minutes}분";
    } else if (targetSoc == 100.0) {
      if (_soc >= 99.5) return "완료";

      double totalHours = 0.0;
      if (_soc < 80.0) {
        double kwhTo80 = _batteryTotalKwh * ((80.0 - _soc) / 100.0);
        totalHours += (kwhTo80 / _chargePowerKw);
      }
      if (_soc < 90.0) {
        double startSoc = _soc < 80.0 ? 80.0 : _soc;
        double kwh80to90 = _batteryTotalKwh * ((90.0 - startSoc) / 100.0);
        double power80to90 = (_chargePowerKw < 15.0) ? _chargePowerKw : 15.0;
        totalHours += (kwh80to90 / power80to90);
      }
      double startSoc90 = _soc < 90.0 ? 90.0 : _soc;
      double kwh90to100 = _batteryTotalKwh * ((100.0 - startSoc90) / 100.0);
      double power90to100 = (_chargePowerKw < 6.0) ? _chargePowerKw : 6.0;
      totalHours += (kwh90to100 / power90to100);

      int totalMinutes = (totalHours * 60).round() + 10;
      return "${totalMinutes}분";
    }
    return "--";
  }

  String _calculateCampingRemainingTime(double targetSoc) {
    double consumeKw = (_voltage * _current).abs() / 1000.0;
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

  String _calculateChargeRatePerHour() {
    if (_chargePowerKw < 0.2) return "(0.0 %/h)";
    double rate = (_chargePowerKw / _batteryTotalKwh) * 100.0;
    return "(+${rate.toStringAsFixed(1)} %/h)";
  }

  Map<String, int> _calculateDetailedFuelCosts() {
    if (_accumulatedRealTripKm <= 0.05) {
      return {'carnival': 0, 'masada': 0, 'saved': 0};
    }
    double carnivalCost = _accumulatedRealTripKm * (1800.0 / 7.0);
    double totalConsumedKwh = _driveEnergyKwh + _hvacEnergyKwh;
    double masadaCost = totalConsumedKwh * 300.0;
    double saved = carnivalCost - masadaCost;

    return {
      'carnival': carnivalCost.round(),
      'masada': masadaCost.round(),
      'saved': saved > 0 ? saved.round() : 0,
    };
  }

  Map<String, dynamic> _getCellBalanceStatus() {
    int d = _cellDeltaMv;
    if (d <= 25) return {'status': '최적(S)', 'desc': '완벽 밸런싱', 'color': const Color(0xFF00E676)};
    if (d <= 50) return {'status': '양호(A)', 'desc': '정상 범위', 'color': const Color(0xFF00E5FF)};
    if (d <= 80) return {'status': '주의(B)', 'desc': '완속 충전 권장', 'color': const Color(0xFFFFD600)};
    return {'status': '점검(C)', 'desc': '셀 편차 과다', 'color': const Color(0xFFFF5252)};
  }

  Map<String, dynamic> _getLoadGrade(double avgLoadPct) {
    if (avgLoadPct <= 30.0) {
      return {'text': '최적', 'color': const Color(0xFF00E676)};
    } else if (avgLoadPct <= 45.0) {
      return {'text': '표준', 'color': const Color(0xFF00E5FF)};
    } else if (avgLoadPct <= 65.0) {
      return {'text': '주의', 'color': const Color(0xFFFF9100)};
    } else {
      return {'text': '과부하', 'color': const Color(0xFFFF5252)};
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0),
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 4),
              Expanded(
                child: _isCampingMode ? _buildCampingDashboard() : _buildStandardDashboard(),
              ),
              const SizedBox(height: 4),
              _buildPowerBar(),
              const SizedBox(height: 4),
              _buildBottomStatusBar(),
              const SizedBox(height: 4),
              _buildExtendedAdvancedBar(),
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
        Row(
          children: [
            if (_isWaterAlarm)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.redAccent, width: 1.2),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 18),
                    SizedBox(width: 6),
                    Text(
                      "⚠️ 배터리 팩 수분 감지 주의 (점검 권장)",
                      style: TextStyle(color: Colors.redAccent, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              )
            else
              Text(
                _isCampingMode ? "MASADA VAN  CAMPING MODE" : "MASADA VAN  EV MONITOR",
                style: TextStyle(
                  color: _isCampingMode ? const Color(0xFFFFB300) : const Color(0xFF00E676),
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _currentGear == "N" ? const Color(0xFFFFB300).withOpacity(0.2) : const Color(0xFF1E242C),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _currentGear == "N" ? const Color(0xFFFFB300) : Colors.white24),
              ),
              child: Text(
                "기어: $_currentGear",
                style: TextStyle(color: _currentGear == "N" ? const Color(0xFFFFB300) : Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        Row(
          children: [
            GestureDetector(
              onTap: () {
                setState(() {
                  _isCampingMode = !_isCampingMode;
                  _neutralDurationSeconds = 0;
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: _isCampingMode ? const Color(0xFFFFB300).withOpacity(0.2) : const Color(0xFF1E242C),
                  borderRadius: BorderRadius.circular(10),
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
                      size: 16,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _isCampingMode ? "캠핑 모드 (ON)" : "캠핑 모드",
                      style: TextStyle(
                        color: _isCampingMode ? const Color(0xFFFFB300) : Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _connectToLogger,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E242C),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _isConnected ? const Color(0xFF00E676) : Colors.redAccent),
                ),
                child: Row(
                  children: [
                    Icon(Icons.circle, color: _isConnected ? const Color(0xFF00E676) : Colors.redAccent, size: 9),
                    const SizedBox(width: 5),
                    Text(
                      _isConnected ? "EvLogger 연결됨" : (_isConnecting ? "연결 시도 중..." : "블루투스 재연결"),
                      style: TextStyle(color: _isConnected ? const Color(0xFF00E676) : Colors.redAccent, fontSize: 13, fontWeight: FontWeight.bold),
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
        Expanded(flex: 25, child: _buildLeftPanel()),
        const SizedBox(width: 10),
        Expanded(flex: 50, child: _buildCenterSocGauge()),
        const SizedBox(width: 10),
        Expanded(flex: 25, child: _buildRightPanel()),
      ],
    );
  }

  Widget _buildCampingDashboard() {
    double liveWatts = (_voltage * _current).abs();
    if (liveWatts > 65000) liveWatts = 0.0;
    double percentPerHour = liveWatts > 0 ? (liveWatts / (_batteryTotalKwh * 1000)) * 100 : 0.0;

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
                const Text("현재 배터리 잔량", style: TextStyle(color: Colors.white54, fontSize: 15)),
                const SizedBox(height: 3),
                Text(
                  "${_soc.toStringAsFixed(1)} %",
                  style: const TextStyle(color: Color(0xFF00E676), fontSize: 48, fontWeight: FontWeight.bold),
                ),
                const Divider(color: Colors.white12, height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Column(
                      children: [
                        const Text("실시간 소모 전력", style: TextStyle(color: Colors.white54, fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(
                          "${liveWatts.toStringAsFixed(0)} W",
                          style: const TextStyle(color: Color(0xFFFFB300), fontSize: 22, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    Column(
                      children: [
                        const Text("시간당 소모율", style: TextStyle(color: Colors.white54, fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(
                          "${percentPerHour.toStringAsFixed(1)} %/h",
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 22, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
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
              const SizedBox(height: 10),
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
              Text(title, style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w500)),
              Text(subInfo, style: const TextStyle(color: Colors.white38, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            remainingTime,
            style: TextStyle(color: accentColor, fontSize: 36, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftPanel() {
    Color effThemeColor = _getEfficiencyColor(_efficiencyScore);
    Map<String, int> fuelCosts = _calculateDetailedFuelCosts();

    return Column(
      children: [
        Expanded(
          child: Container(
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
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("💰 실시간 유류비 절감", style: TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w500)),
                    Text("카니발 대비", style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text("+${fuelCosts['saved']}", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 38, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 4),
                    const Text("원 절약", style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("카니발: ${fuelCosts['carnival']}원", style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    Text("마사다: ${fuelCosts['masada']}원", style: const TextStyle(color: Color(0xFFFFB300), fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        // 💡 [수정 요청 1: 복합 전비 기반 BMS 주행가능거리]
        Expanded(
          child: _buildCard(
            title: "BMS 주행가능거리 (복합 전비)",
            valueText: _bmsDistance.toStringAsFixed(1),
            unitText: "km",
            valueColor: effThemeColor,
          ),
        ),
      ],
    );
  }

  // 💡 [수정 요청 3: 이번 주행 순수 전비(D, R)를 중앙 게이지에 표시]
  Widget _buildCenterSocGauge() {
    Color effThemeColor = _getEfficiencyColor(_efficiencyScore);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF13171D),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF222A35)),
      ),
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 320,
              height: 320,
              child: CircularProgressIndicator(
                value: (_soc / 100.0).clamp(0.0, 1.0),
                strokeWidth: 24,
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
                    Text(_pureDriveTripEfficiency.toStringAsFixed(1), style: TextStyle(color: effThemeColor, fontSize: 32, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 5),
                    Text("km/kWh", style: TextStyle(color: effThemeColor.withOpacity(0.85), fontSize: 20, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(_soc.toStringAsFixed(1), style: TextStyle(color: effThemeColor, fontSize: 72, fontWeight: FontWeight.bold)),
                    Text("%", style: TextStyle(color: effThemeColor, fontSize: 30, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // 💡 [수정 요청 2: 우측 상단에 '실시간 주행 효율(1분)' 배치]
  Widget _buildRightPanel() {
    Color effThemeColor = _getEfficiencyColor(_efficiencyScore);
    double regenKw = _current < 0 ? _chargePowerKw : 0.0;
    double regenPct = (_accumulatedRegenKwh / _batteryTotalKwh) * 100.0;
    double gainedKm = _accumulatedRegenKwh * _pureDriveTripEfficiency;

    double totalConsumed = _driveEnergyKwh + _hvacEnergyKwh;
    int drivePct = totalConsumed > 0.01 ? ((_driveEnergyKwh / totalConsumed) * 100).round() : 85;
    int hvacPct = 100 - drivePct;

    return Column(
      children: [
        // 💡 [우측 상단: 실시간 주행 효율 (1분 주기 점수 & 뱃지)]
        Expanded(
          child: Container(
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
                    const Text("🌱 실시간 주행 효율 (1분)", style: TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w500)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: effThemeColor.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: effThemeColor, width: 0.8),
                      ),
                      child: Text(
                        _efficiencyScore >= 80 ? "최고 효율" : (_efficiencyScore >= 50 ? "보통 주행" : "급가속/비효율"),
                        style: TextStyle(color: effThemeColor, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text("$_efficiencyScore", style: TextStyle(color: effThemeColor, fontSize: 44, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 5),
                    const Text("점", style: TextStyle(color: Colors.white54, fontSize: 18, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text("${_recent1MinEfficiency.toStringAsFixed(1)} km/kWh", style: TextStyle(color: effThemeColor.withOpacity(0.8), fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (_efficiencyScore / 100.0).clamp(0.0, 1.0),
                    backgroundColor: const Color(0xFF222A35),
                    valueColor: AlwaysStoppedAnimation<Color>(effThemeColor),
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        // [우측 하단: 회생 이득 및 주행/공조 비율 유지]
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF13171D),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: regenKw > 0.5 ? const Color(0xFFFF9100).withOpacity(0.6) : const Color(0xFF222A35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("회생 ${regenKw.toStringAsFixed(1)}kW", style: TextStyle(color: regenKw > 0.1 ? const Color(0xFFFF9100) : Colors.white54, fontSize: 17, fontWeight: FontWeight.bold)),
                    Text("+${regenPct.toStringAsFixed(1)}%", style: const TextStyle(color: Color(0xFF00E676), fontSize: 17, fontWeight: FontWeight.bold)),
                    Text("+${gainedKm.toStringAsFixed(1)}km 이득", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 17, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    const Text("주행 ", style: TextStyle(color: Colors.white70, fontSize: 16)),
                    Text("$drivePct%", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 30, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 12),
                    const Text("· 공조 ", style: TextStyle(color: Colors.white70, fontSize: 16)),
                    Text("$hvacPct%", style: const TextStyle(color: Color(0xFFFFB300), fontSize: 30, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: drivePct / 100.0,
                    backgroundColor: const Color(0xFFFFB300),
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                    minHeight: 10,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCard({required String title, required String valueText, required String unitText, required Color valueColor}) {
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
          Text(title, style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(valueText, style: TextStyle(color: valueColor, fontSize: 46, fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Text(unitText, style: const TextStyle(color: Colors.white54, fontSize: 22, fontWeight: FontWeight.bold)),
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

    bool isRegenLimited = (_soc >= 90.5) || (_batteryTemp < 5.0);

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
              Row(
                children: [
                  const Text("◀ 회생제동 (REGEN)", style: TextStyle(color: Color(0xFFFF9100), fontSize: 13, fontWeight: FontWeight.bold)),
                  if (isRegenLimited) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.redAccent, width: 0.8),
                      ),
                      child: const Text("⚠️ 회생제한 (풋브레이크 권장)", style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("실시간: ${_powerKw.toStringAsFixed(1)} kW", style: TextStyle(color: dynamicBarColor, fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Text("(한계: ${safeLimitKw.toStringAsFixed(0)}kW)", style: const TextStyle(color: Colors.white38, fontSize: 13)),
                ],
              ),
              const Text("가속 출력 (POWER) ▶", style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, constraints) {
              double barWidth = constraints.maxWidth;
              double pinLeft = (barWidth * limitNormalized) - 4.0;
              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  LinearProgressIndicator(value: normalized, backgroundColor: const Color(0xFF222A35), valueColor: AlwaysStoppedAnimation<Color>(dynamicBarColor), minHeight: 12),
                  Positioned(left: (barWidth * 0.5) - 1.0, child: Container(width: 2.0, height: 16, color: Colors.white54)),
                  Positioned(
                    left: pinLeft.clamp(0.0, barWidth - 8.0),
                    child: Container(
                      width: 8,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(2.0),
                        boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 3, offset: Offset(0, 1))],
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
    Map<String, dynamic> tempGrade = _getBatteryTempGrade();
    double totalConsumedKwh = _driveEnergyKwh + _hvacEnergyKwh;
    double consumedPct = (_batteryTotalKwh > 0) ? (totalConsumedKwh / _batteryTotalKwh) * 100.0 : 0.0;
    double liveConsumeWatts = (_voltage * _current).abs();
    if (liveConsumeWatts > 65000) liveConsumeWatts = 0.0;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildBottomCard(title: "운행 시간", child: Text(_formatDrivingTime(_drivingSeconds), style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 16, fontWeight: FontWeight.bold))),
        _buildBottomCard(
          title: "이번 운행 소모량",
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("${totalConsumedKwh.toStringAsFixed(1)} kWh", style: const TextStyle(color: Color(0xFFFFB300), fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(width: 4),
              Text("(-${consumedPct.toStringAsFixed(1)}%)", style: const TextStyle(color: Color(0xFFFF5252), fontSize: 13, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        _buildBottomCard(title: "실시간 소모 전력", child: Text("${liveConsumeWatts.toStringAsFixed(0)} W", style: TextStyle(color: liveConsumeWatts > 1000 ? const Color(0xFFFFB300) : Colors.white, fontSize: 16, fontWeight: FontWeight.bold))),
        _buildBottomCard(title: "배터리 건강(SOH)", child: Text("$_soh %", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 16, fontWeight: FontWeight.bold))),
        _buildBottomCard(
          title: "배터리온도 & 급속허용",
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("${_batteryTemp.toStringAsFixed(1)}°C", style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(color: (tempGrade['color'] as Color).withOpacity(0.2), borderRadius: BorderRadius.circular(4), border: Border.all(color: tempGrade['color'] as Color, width: 0.8)),
                    child: Text("${tempGrade['grade']} (${tempGrade['amp']})", style: TextStyle(color: tempGrade['color'] as Color, fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(width: 90, height: 5, decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), gradient: const LinearGradient(colors: [Color(0xFF2979FF), Color(0xFF00E5FF), Color(0xFF00E676), Color(0xFFFFD600), Color(0xFFFF9100), Color(0xFFFF5252)]))),
                  Positioned(
                    left: (((_batteryTemp + 10) / 70.0).clamp(0.0, 1.0) * 82),
                    child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black, blurRadius: 2)])),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 💡 [수정 요청 2: 하단 바 중앙에 '실시간 충전량' 컴팩트 배치]
  Widget _buildExtendedAdvancedBar() {
    double avgLoadPct = _loadSampleCount > 0 ? (_accumulatedLoadPct / _loadSampleCount) : 0.0;
    Map<String, dynamic> cellBal = _getCellBalanceStatus();
    Map<String, dynamic> loadGrade = _getLoadGrade(avgLoadPct);

    bool isChargingOrRegen = _chargePowerKw > 0.1;
    bool isFastCharge = _chargePowerKw > 10.0;
    String chargeLabel = isChargingOrRegen ? (isFastCharge ? "⚡ 급속 충전 중" : "🔌 완속 충전 중") : "⚡ 실시간 충전/회생";

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // 1. 이번주행 평균 부하율
        Expanded(
          flex: 32,
          child: _buildExtendedCard(
            title: "⚡ 이번주행 평균 부하율",
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text("${avgLoadPct.toStringAsFixed(1)}", style: TextStyle(color: loadGrade['color'] as Color, fontSize: 16, fontWeight: FontWeight.bold)),
                const Text(" %", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: (loadGrade['color'] as Color).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: loadGrade['color'] as Color, width: 0.8),
                  ),
                  child: Text(
                    "${loadGrade['text']}",
                    style: TextStyle(color: loadGrade['color'] as Color, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        // 💡 [2. 하단 중앙으로 이동한 실시간 충전/회생 상태 카드]
        Expanded(
          flex: 38,
          child: _buildExtendedCard(
            title: chargeLabel,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  "${_chargePowerKw.toStringAsFixed(1)} kW",
                  style: TextStyle(
                    color: isChargingOrRegen ? const Color(0xFFFFB300) : Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4)),
                  ),
                  child: Text("80% ${_calculateTimeToSoc(80.0)}", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 10, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E676).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFF00E676).withOpacity(0.4)),
                  ),
                  child: Text("100% ${_calculateTimeToSoc(100.0)}", style: const TextStyle(color: Color(0xFF00E676), fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        // 3. 셀 밸런싱 편차 게이지
        Expanded(
          flex: 30,
          child: _buildExtendedCard(
            title: "⚖️ 셀 밸런싱 편차 (ΔV)",
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text("$_cellDeltaMv", style: TextStyle(color: cellBal['color'] as Color, fontSize: 16, fontWeight: FontWeight.bold)),
                const Text(" mV ", style: TextStyle(color: Colors.white70, fontSize: 12)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: (cellBal['color'] as Color).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: cellBal['color'] as Color, width: 0.8),
                  ),
                  child: Text("${cellBal['status']}", style: TextStyle(color: cellBal['color'] as Color, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomCard({required String title, required Widget child}) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2.0),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF13171D),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFF222A35)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500)),
            const SizedBox(height: 3),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildExtendedCard({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF13171D),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFF222A35)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500)),
          const SizedBox(height: 3),
          child,
        ],
      ),
    );
  }
}
