import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
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
        scaffoldBackgroundColor: const Color(0xFF0A0C0F),
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
  late PageController _pageController;
  int _currentPageIndex = 0;
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

  String _currentGear = "D";
  int _neutralDurationSeconds = 0;

  int _accelPedalPct = 0;
  double _ptcTemp = 20.0;
  double _evapTemp = 15.0;
  double _envTemp = 25.0;

  bool _isFootBrakePressed = false;
  int _totalDecelSeconds = 0;
  int _onePedalRegenSeconds = 0;
  int _onePedalScorePct = 100;

  double _energyDriveKwh = 0.0;
  double _energyPtcKwh = 0.0;
  double _energyAcKwh = 0.0;
  double _energyStandbyKwh = 0.0;

  double _totalCumulativeChargeKwh = 0.0;
  int _chargeTimesCount = 0;
  int _dischargeTimesCount = 0;
  int _insulationResistanceKohm = 3640;
  bool _isDcSwitchClosed = true;
  bool _isPackCoverClosed = true;
  int _cellMaxId = 1;
  int _cellMinId = 1;

  int _cellMaxMv = 3315;
  int _cellMinMv = 3300;
  int _cellDeltaMv = 15;

  final List<_DrivingSample> _recent1MinSamples = [];
  double _recent1MinEfficiency = 5.7;
  int _efficiencyScore = 80;

  double _pureDriveEnergyKwh = 0.0;
  double _pureDriveDistanceKm = 0.0;
  double _pureDriveTripEfficiency = 5.7;

  double _accumulatedRegenKwh = 0.0;
  int _drivingSeconds = 0;
  int _loadSampleCount = 0;
  double _accumulatedLoadPct = 0.0;
  double _accumulatedPowerSumKw = 0.0;
  int _powerSampleCount = 0;
  Timer? _drivingTimer;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
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
    _pageController.dispose();
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

    // 1. BMS SOC & 최고/최저 셀 전압[span_3](start_span)[span_3](end_span)[span_4](start_span)[span_4](end_span)
    if (id == 0x0CFF7D03) {
      int rawSoc = d[1];
      if (rawSoc > 0 && rawSoc <= 200) {
        _soc = rawSoc * 0.5;
      }
      _cellMaxId = d[2];
      int hVolt = (d[4] << 8) | d[3];
      _cellMinId = d[5];
      int lVolt = (d[7] << 8) | d[6];
      if (hVolt >= 2500 && hVolt <= 4200) _cellMaxMv = hVolt;
      if (lVolt >= 2500 && lVolt <= 4200) _cellMinMv = lVolt;
      _cellDeltaMv = (_cellMaxMv - _cellMinMv).clamp(0, 300);
      if (mounted) setState(() {});
      return true;
    }

    // 2. SOH, 전압, 전류, 배터리 온도[span_5](start_span)[span_5](end_span)[span_6](start_span)[span_6](end_span)
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

    // 3. 절연 저항[span_7](start_span)[span_7](end_span)[span_8](start_span)[span_8](end_span)
    if (id == 0x0CFF7F03) {
      int rawIso = (d[7] << 8) | d[6];
      if (rawIso > 0) _insulationResistanceKohm = rawIso * 10;
      if (mounted) setState(() {});
      return true;
    }

    // 4. 공조 3종 온도 & 악셀/기어 (0x19014801 VCU_Meter 전용 파싱)[span_9](start_span)[span_9](end_span)
    if (id == 0x19014801 || id == 0x09014801) {
      int rawGear = (d[4] >> 2) & 0x03;
      if (rawGear == 0) _currentGear = "N";
      else if (rawGear == 1) _currentGear = "D";
      else if (rawGear == 2) _currentGear = "R";
      else if (rawGear == 3) _currentGear = "P";

      if (_currentGear == "D" && _isCampingMode) {
        _isCampingMode = false;
        _neutralDurationSeconds = 0;
      }

      if (d[3] >= 0 && d[3] <= 100) {
        _accelPedalPct = d[3];
      }

      _isFootBrakePressed = (d[4] & 0x01) != 0;

      // 공조 3종 온도 (CAN DB 정밀 규격: Raw - 50)[span_10](start_span)[span_10](end_span)
      int rawEnv = d[5];
      if (rawEnv > 0 && rawEnv <= 255) {
        _envTemp = (rawEnv - 50).toDouble();
      }

      int rawEvap = d[6];
      if (rawEvap > 0 && rawEvap <= 255) {
        _evapTemp = (rawEvap - 50).toDouble();
      }

      int rawPtc = d[7];
      if (rawPtc > 0 && rawPtc <= 255) {
        _ptcTemp = (rawPtc - 50).toDouble();
      }

      if (mounted) setState(() {});
      return true;
    }

    // 5. 별도 가속/기어 메시지[span_11](start_span)[span_11](end_span)
    if (id == 0x18FFDC01) {
      if (d[3] >= 0 && d[3] <= 100) {
        _accelPedalPct = d[3];
      }
      int rawGear = (d[4] >> 2) & 0x03;
      if (rawGear == 0) _currentGear = "N";
      else if (rawGear == 1) _currentGear = "D";
      else if (rawGear == 2) _currentGear = "R";
      else if (rawGear == 3) _currentGear = "P";

      _isFootBrakePressed = (d[4] & 0x01) != 0;
      if (mounted) setState(() {});
      return true;
    }

    // 6. 실시간 차량 속도[span_12](start_span)[span_12](end_span)[span_13](start_span)[span_13](end_span)
    if (id == 0x190048D5 || id == 0x18FEDCD5 || id == 0x090048D5) {
      double rawSpd = d[0].toDouble();
      _realVehicleSpeedKmh = (rawSpd > 140.0) ? rawSpd * 0.5 : rawSpd;
      if (mounted) setState(() {});
      return true;
    }

    // 7. 배터리 기밀/스위치/수분[span_14](start_span)[span_14](end_span)[span_15](start_span)[span_15](end_span)
    if (id == 0x0CFF8103) {
      _isWaterAlarm = (d[6] & 0x01) != 0;
      _isDcSwitchClosed = (d[6] & 0x04) != 0;
      _isPackCoverClosed = (d[6] & 0x08) != 0;
      if (mounted) setState(() {});
      return true;
    }

    // 8. 충/방전 횟수[span_16](start_span)[span_16](end_span)[span_17](start_span)[span_17](end_span)
    if (id == 0x0CFF8003) {
      _chargeTimesCount = (d[3] << 8) | d[2];
      _dischargeTimesCount = (d[5] << 8) | d[4];
      if (mounted) setState(() {});
      return true;
    }

    // 9. 평생 누적 충전량[span_18](start_span)[span_18](end_span)[span_19](start_span)[span_19](end_span)
    if (id == 0x0CFF8503 || id == 0x0CFF8501) {
      int rawCumul = (d[5] << 24) | (d[4] << 16) | (d[3] << 8) | d[2];
      if (rawCumul > 0) {
        _totalCumulativeChargeKwh = rawCumul * 0.1;
      }
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

          if (_currentGear == "N" || (_realVehicleSpeedKmh < 0.5 && _powerKw.abs() < 0.3) || _chargePowerKw > 0.3) {
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
            double currentSpeed = _realVehicleSpeedKmh > 0.5 ? _realVehicleSpeedKmh : 0.0;
            double secondDistKm = currentSpeed / 3600.0;

            if (_current < -0.5 && _chargePowerKw > 0.1) {
              _accumulatedRegenKwh += (_chargePowerKw / 3600.0);
            }

            if (_powerKw > 0.05) {
              _accumulatedPowerSumKw += _powerKw;
              _powerSampleCount++;

              double secKwh = _powerKw / 3600.0;
              if (_ptcTemp > _envTemp + 10.0) {
                double ptcEstKw = ((_ptcTemp - _envTemp) / 40.0 * 3.5).clamp(0.5, 4.0);
                double ptcSec = (ptcEstKw / 3600.0).clamp(0.0, secKwh);
                _energyPtcKwh += ptcSec;
                secKwh -= ptcSec;
              }
              if (_evapTemp < 12.0 && secKwh > 0) {
                double acEstKw = ((20.0 - _evapTemp) / 15.0 * 2.0).clamp(0.4, 2.5);
                double acSec = (acEstKw / 3600.0).clamp(0.0, secKwh);
                _energyAcKwh += acSec;
                secKwh -= acSec;
              }
              if (secKwh > 0) {
                double stdbySec = (0.3 / 3600.0).clamp(0.0, secKwh);
                _energyStandbyKwh += stdbySec;
                secKwh -= stdbySec;
              }
              if (secKwh > 0) {
                _energyDriveKwh += secKwh;
              }

              double liveLoad = (_powerKw / 60.0 * 100.0).clamp(0.0, 100.0);
              _accumulatedLoadPct += liveLoad;
              _loadSampleCount++;
            }

            if (_realVehicleSpeedKmh > 5.0 && _powerKw <= 0.0) {
              _totalDecelSeconds++;
              if (!_isFootBrakePressed) {
                _onePedalRegenSeconds++;
              }
              if (_totalDecelSeconds > 0) {
                _onePedalScorePct = ((_onePedalRegenSeconds / _totalDecelSeconds) * 100).round().clamp(0, 100);
              }
            }

            if (secondDistKm > 0.0) {
              _accumulatedRealTripKm += secondDistKm;
            }

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

  void _update1MinEfficiencyAndBmsDistance() {
    if (_realVehicleSpeedKmh > 3.0) {
      _recent1MinSamples.add(_DrivingSample(_powerKw, _realVehicleSpeedKmh));
      if (_recent1MinSamples.length > 60) {
        _recent1MinSamples.removeAt(0);
      }

      if (_recent1MinSamples.length >= 5) {
        double totalNetKwh = 0.0;
        double totalDistanceKm = 0.0;
        for (var s in _recent1MinSamples) {
          totalNetKwh += (s.powerKw / 3600.0);
          totalDistanceKm += (s.realSpeedKmh / 3600.0);
        }
        if (totalNetKwh > 0.003 && totalDistanceKm > 0.005) {
          _recent1MinEfficiency = (totalDistanceKm / totalNetKwh).clamp(2.0, 12.0);
        }
      }

      double rawScore = ((_recent1MinEfficiency - 3.0) / (8.0 - 3.0)) * 80.0 + 20.0;
      _efficiencyScore = rawScore.clamp(20.0, 100.0).round();
    }

    double baseDistance30Pct = (_soc * 2.4) * 0.3;
    double currentRemainKwh = (_batteryTotalKwh * (_soh / 100.0)) * (_soc / 100.0);
    double dynamicDistance70Pct = (currentRemainKwh * _pureDriveTripEfficiency) * 0.7;

    _bmsDistance = double.parse((baseDistance30Pct + dynamicDistance70Pct).toStringAsFixed(1));
  }

  String _calculateTimeToSoc(double targetSoc) {
    if (_chargePowerKw < 0.3) return "--";

    if (targetSoc == 80.0) {
      if (_soc >= 80.0) return "완료";
      double neededKwh = _batteryTotalKwh * ((80.0 - _soc) / 100.0);
      int totalMinutes = ((neededKwh / _chargePowerKw) * 60).round();
      return _formatHoursAndMinutes(totalMinutes);
    } else if (targetSoc == 100.0) {
      if (_soc >= 99.5) return "완료";

      if (_chargePowerKw <= 10.0) {
        double neededKwh = _batteryTotalKwh * ((100.0 - _soc) / 100.0);
        int totalMinutes = ((neededKwh / _chargePowerKw) * 60).round();
        return _formatHoursAndMinutes(totalMinutes);
      }

      double totalHours = 0.0;
      if (_soc < 80.0) {
        double kwhTo80 = _batteryTotalKwh * ((80.0 - _soc) / 100.0);
        totalHours += (kwhTo80 / _chargePowerKw);
      }
      if (_soc < 90.0) {
        double startSoc = _soc < 80.0 ? 80.0 : _soc;
        double kwh80to90 = _batteryTotalKwh * ((90.0 - startSoc) / 100.0);
        totalHours += (kwh80to90 / 15.0);
      }
      double startSoc90 = _soc < 90.0 ? 90.0 : _soc;
      double kwh90to100 = _batteryTotalKwh * ((100.0 - startSoc90) / 100.0);
      totalHours += (kwh90to100 / 6.0);

      int totalMinutes = (totalHours * 60).round() + 5;
      return _formatHoursAndMinutes(totalMinutes);
    }
    return "--";
  }

  String _formatHoursAndMinutes(int totalMinutes) {
    if (totalMinutes <= 0) return "완료";
    if (totalMinutes < 60) return "$totalMinutes분";
    int h = totalMinutes ~/ 60;
    int m = totalMinutes % 60;
    return (m == 0) ? "$h시간" : "$h시간 $m분";
  }

  String _calculateCampingRemainingTime(double targetSoc) {
    double consumeKw = (_voltage * _current).abs() / 1000.0;
    if (consumeKw < 0.05) return "소모 없음";

    double currentKwh = _batteryTotalKwh * (_soc / 100.0);
    double targetKwh = _batteryTotalKwh * (targetSoc / 100.0);
    double availableKwh = currentKwh - targetKwh;

    if (availableKwh <= 0) return "도달 완료";

    double hours = availableKwh / consumeKw;
    if (hours > 99) return "99시간 이상";

    int totalMinutes = (hours * 60).round();
    return _formatHoursAndMinutes(totalMinutes);
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

  Map<String, dynamic> _getBatteryTempGrade() {
    double t = _batteryTemp;
    if (t >= 15.0 && t <= 45.0) return {'grade': 'S', 'amp': '120A', 'color': const Color(0xFF00E676), 'desc': '최적 풀파워'};
    else if (t >= 10.0 && t < 15.0) return {'grade': 'A', 'amp': '63A', 'color': const Color(0xFF00E5FF), 'desc': '저온 감발'};
    else if (t > 45.0 && t <= 48.0) return {'grade': 'A', 'amp': '63A', 'color': const Color(0xFFFFD600), 'desc': '고온 진입'};
    else if (t > 48.0 && t <= 54.0) return {'grade': 'B', 'amp': '42A', 'color': const Color(0xFFFF9100), 'desc': '고온 감발'};
    else if (t >= 0.0 && t < 10.0) return {'grade': 'C', 'amp': '25A', 'color': const Color(0xFF2979FF), 'desc': '극저온'};
    else return {'grade': 'D', 'amp': '13A', 'color': const Color(0xFFFF5252), 'desc': '초저속/제한'};
  }

  Map<String, int> _calculateDetailedFuelCosts() {
    if (_accumulatedRealTripKm <= 0.05) {
      return {'carnival': 0, 'masada': 0, 'saved': 0};
    }
    double carnivalCost = _accumulatedRealTripKm * (1800.0 / 7.0);
    double totalConsumedKwh = _energyDriveKwh + _energyPtcKwh + _energyAcKwh + _energyStandbyKwh;
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

  Map<String, int> _calculateEnergyDistribution() {
    double total = _energyDriveKwh + _energyPtcKwh + _energyAcKwh + _energyStandbyKwh;
    if (total < 0.01) {
      return {'drive': 85, 'ptc': 5, 'ac': 5, 'stdby': 5};
    }
    int d = ((_energyDriveKwh / total) * 100).round();
    int p = ((_energyPtcKwh / total) * 100).round();
    int a = ((_energyAcKwh / total) * 100).round();
    int s = (100 - d - p - a).clamp(0, 100);
    return {'drive': d, 'ptc': p, 'ac': a, 'stdby': s};
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 4),
              Expanded(
                child: _isCampingMode
                    ? _buildCampingDashboard()
                    : PageView(
                        controller: _pageController,
                        physics: const BouncingScrollPhysics(),
                        onPageChanged: (index) {
                          setState(() {
                            _currentPageIndex = index;
                          });
                        },
                        children: [
                          _buildMainDriveDashboard(),
                          _buildBatteryDiagnosticsPage(),
                        ],
                      ),
              ),
              const SizedBox(height: 4),
              _buildBottomSingleUnifiedBar(),
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.redAccent, width: 1.0),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 16),
                    SizedBox(width: 4),
                    Text(
                      "⚠️ 배터리 수분 감지",
                      style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              )
            else
              Text(
                _isCampingMode
                    ? (_chargePowerKw > 0.3 ? "MASADA  CHARGING & CAMPING" : "MASADA  CAMPING")
                    : (_currentPageIndex == 0 ? "MASADA VAN  EV MONITOR" : "BMS  BATTERY DIAGNOSTICS"),
                style: TextStyle(
                  color: _isCampingMode ? const Color(0xFFFFB300) : const Color(0xFF00E676),
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: _currentGear == "N" ? const Color(0xFFFFB300).withOpacity(0.15) : const Color(0xFF1E242C),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _currentGear == "N" ? const Color(0xFFFFB300) : Colors.white24, width: 0.8),
              ),
              child: Text(
                _currentGear,
                style: TextStyle(
                  color: _currentGear == "N" ? const Color(0xFFFFB300) : Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (!_isCampingMode)
              GestureDetector(
                onTap: () {
                  _pageController.animateToPage(
                    _currentPageIndex == 0 ? 1 : 0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.purpleAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.purpleAccent.withOpacity(0.6), width: 0.8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.swipe, color: Colors.purpleAccent, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        _currentPageIndex == 0 ? "배터리 진단 ➔" : "◀ 메인 계기판",
                        style: const TextStyle(color: Colors.purpleAccent, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(width: 8),
            if (_isFootBrakePressed)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.redAccent, width: 1.0),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.stop_circle_outlined, color: Colors.redAccent, size: 12),
                    SizedBox(width: 3),
                    Text("🛑 풋브레이크 개입", style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
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
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _isCampingMode ? const Color(0xFFFFB300).withOpacity(0.2) : const Color(0xFF1E242C),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _isCampingMode ? const Color(0xFFFFB300) : Colors.white30,
                    width: 1.0,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isCampingMode ? Icons.bedtime : Icons.night_shelter_outlined,
                      color: _isCampingMode ? const Color(0xFFFFB300) : Colors.white70,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _isCampingMode ? "캠핑 (ON)" : "캠핑 모드",
                      style: TextStyle(
                        color: _isCampingMode ? const Color(0xFFFFB300) : Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: _connectToLogger,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E242C),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _isConnected ? const Color(0xFF00E676) : Colors.redAccent),
                ),
                child: Row(
                  children: [
                    Icon(Icons.circle, color: _isConnected ? const Color(0xFF00E676) : Colors.redAccent, size: 8),
                    const SizedBox(width: 4),
                    Text(
                      _isConnected ? "연결됨" : (_isConnecting ? "연결중..." : "재연결"),
                      style: TextStyle(color: _isConnected ? const Color(0xFF00E676) : Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
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

  // =========================================================================
  // [1페이지] 메인 운전 대시보드
  // =========================================================================
  Widget _buildMainDriveDashboard() {
    return Row(
      children: [
        Expanded(flex: 30, child: _buildFuelSavingCard()),
        const SizedBox(width: 8),
        Expanded(flex: 40, child: _buildArcHubGaugeCenter()),
        const SizedBox(width: 8),
        Expanded(flex: 30, child: _buildEfficiencyEnergyCard()),
      ],
    );
  }

  Widget _buildFuelSavingCard() {
    Map<String, int> fuelCosts = _calculateDetailedFuelCosts();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF13171D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF222A35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.savings_outlined, color: Color(0xFF00E5FF), size: 20),
                  SizedBox(width: 6),
                  Text("실시간 유류비 절감", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                decoration: BoxDecoration(color: const Color(0xFF00E5FF).withOpacity(0.15), borderRadius: BorderRadius.circular(4)),
                child: const Text("카니발 대비", style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  "+${fuelCosts['saved']}",
                  style: const TextStyle(
                    color: Color(0xFF00E5FF),
                    fontSize: 54,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.5,
                  ),
                ),
                const SizedBox(width: 6),
                const Text("원 절약", style: TextStyle(color: Colors.white70, fontSize: 20, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A212B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("가솔린 카니발 (7km/L)", style: TextStyle(color: Colors.white60, fontSize: 13)),
                    Text("${fuelCosts['carnival']} 원", style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                  ],
                ),
                const Divider(color: Colors.white10, height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("마사다 밴 실시간 전기", style: TextStyle(color: Colors.white60, fontSize: 13)),
                    Text("${fuelCosts['masada']} 원", style: const TextStyle(color: Color(0xFFFFB300), fontSize: 16, fontWeight: FontWeight.w900)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArcHubGaugeCenter() {
    Color effThemeColor = _getEfficiencyColor(_efficiencyScore);
    double accelRatio = (_accelPedalPct / 100.0).clamp(0.0, 1.0);
    double ptcRatio = ((_ptcTemp - 15.0) / 65.0).clamp(0.0, 1.0);
    double acRatio = ((25.0 - _evapTemp) / 25.0).clamp(0.0, 1.0);

    double avgPowerKw = _powerSampleCount > 0 ? (_accumulatedPowerSumKw / _powerSampleCount) : 0.0;
    double safeLimitKw = _getSafePowerLimitKw(_batteryTemp);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF13171D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF222A35)),
      ),
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF1E242C),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white24, width: 0.8),
              ),
              child: Text(
                "외기 ${_envTemp.toStringAsFixed(1)}°C",
                style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                flex: 10,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("ACCEL", style: TextStyle(color: Colors.white54, fontSize: 9, fontWeight: FontWeight.bold)),
                    Text("$_accelPedalPct%", style: const TextStyle(color: Color(0xFF00E676), fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Container(
                        width: 12,
                        decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(6)),
                        child: LayoutBuilder(
                          builder: (c, constraints) => Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              width: 12,
                              height: constraints.maxHeight * accelRatio,
                              decoration: BoxDecoration(color: const Color(0xFF00E676), borderRadius: BorderRadius.circular(6)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 80,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    double hubSize = constraints.maxWidth < constraints.maxHeight ? constraints.maxWidth : constraints.maxHeight;
                    return Center(
                      child: SizedBox(
                        width: hubSize,
                        height: hubSize,
                        child: CustomPaint(
                          painter: _ArcPowerMeterPainter(
                            powerKw: _powerKw,
                            safeLimitKw: safeLimitKw,
                            avgPowerKw: avgPowerKw,
                          ),
                          child: Center(
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                SizedBox(
                                  width: hubSize * 0.72,
                                  height: hubSize * 0.72,
                                  child: CircularProgressIndicator(
                                    value: (_soc / 100.0).clamp(0.0, 1.0),
                                    strokeWidth: 20,
                                    backgroundColor: const Color(0xFF1E242C),
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
                                        Text(_bmsDistance.toStringAsFixed(0), style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w900)),
                                        const SizedBox(width: 2),
                                        const Text("km", style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.baseline,
                                      textBaseline: TextBaseline.alphabetic,
                                      children: [
                                        Text(_soc.toStringAsFixed(1), style: TextStyle(color: effThemeColor, fontSize: 46, fontWeight: FontWeight.w900)),
                                        Text("%", style: TextStyle(color: effThemeColor, fontSize: 20, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(color: effThemeColor.withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
                                      child: Text("${_pureDriveTripEfficiency.toStringAsFixed(1)} km/kWh", style: TextStyle(color: effThemeColor, fontSize: 13, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Expanded(
                flex: 10,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("PTC", style: TextStyle(color: Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold)),
                    Text("${_ptcTemp.toStringAsFixed(0)}°", style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Container(
                        width: 12,
                        decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(6)),
                        child: LayoutBuilder(
                          builder: (c, constraints) {
                            double half = constraints.maxHeight / 2.0;
                            return Stack(children: [
                              Align(alignment: Alignment.center, child: Container(width: 12, height: 2, color: Colors.white54)),
                              Positioned(bottom: half, left: 0, right: 0, child: Container(height: half * ptcRatio, decoration: const BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.vertical(top: Radius.circular(6))))),
                              Positioned(top: half, left: 0, right: 0, child: Container(height: half * acRatio, decoration: const BoxDecoration(color: Color(0xFF00E5FF), borderRadius: BorderRadius.vertical(bottom: Radius.circular(6))))),
                            ]);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text("${_evapTemp.toStringAsFixed(0)}°", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 12, fontWeight: FontWeight.bold)),
                    const Text("A/C", style: TextStyle(color: Color(0xFF00E5FF), fontSize: 9, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEfficiencyEnergyCard() {
    Color effThemeColor = _getEfficiencyColor(_efficiencyScore);
    Map<String, int> dist = _calculateEnergyDistribution();
    bool isStopped = _realVehicleSpeedKmh <= 0.5;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF13171D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF222A35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.bolt, color: Color(0xFF00E676), size: 22),
                  SizedBox(width: 6),
                  Text("효율 & 에너지 분석", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isStopped ? Colors.white10 : effThemeColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: isStopped ? Colors.white24 : effThemeColor, width: 0.8),
                ),
                child: Text(
                  isStopped ? "⏸️ 신호 대기" : "원페달 $_onePedalScorePct%",
                  style: TextStyle(color: isStopped ? Colors.white70 : effThemeColor, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 66,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text("$_efficiencyScore", style: TextStyle(color: effThemeColor, fontSize: 56, fontWeight: FontWeight.w900, letterSpacing: -2.0)),
                          const SizedBox(width: 4),
                          const Text("점", style: TextStyle(color: Colors.white70, fontSize: 22, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _buildVerticalLegendItem("구동 모터", const Color(0xFF00E676), "${dist['drive']}%"),
                      const SizedBox(height: 5),
                      _buildVerticalLegendItem("히터 PTC", Colors.redAccent, "${dist['ptc']}%"),
                      const SizedBox(height: 5),
                      _buildVerticalLegendItem("에어컨 A/C", Colors.cyanAccent, "${dist['ac']}%"),
                      const SizedBox(height: 5),
                      _buildVerticalLegendItem("전장 대기", Colors.white54, "${dist['stdby']}%"),
                    ],
                  ),
                ),
                Expanded(
                  flex: 34,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E242C),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        Expanded(flex: dist['drive']!, child: Container(color: const Color(0xFF00E676))),
                        Expanded(flex: dist['ptc']!, child: Container(color: Colors.redAccent)),
                        Expanded(flex: dist['ac']!, child: Container(color: Colors.cyanAccent)),
                        Expanded(flex: dist['stdby']!, child: Container(color: Colors.white38)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVerticalLegendItem(String title, Color color, String pct) {
    return Row(
      children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 7),
        Text(title, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
        const Spacer(),
        Text(pct, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.bold)),
      ],
    );
  }

  // =========================================================================
  // [2페이지] 배터리 정밀 진단 센터 (게이지 삭제 완료)
  // =========================================================================
  Widget _buildBatteryDiagnosticsPage() {
    Map<String, dynamic> cellBal = _getCellBalanceStatus();
    Map<String, dynamic> tempGrade = _getBatteryTempGrade();

    return Row(
      children: [
        Expanded(
          flex: 33,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF13171D),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF222A35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.bolt, color: Color(0xFF00E676), size: 20),
                    SizedBox(width: 6),
                    Text("급속충전 등급 & 이력", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text("${tempGrade['grade']} 등급 (${tempGrade['amp']})", style: TextStyle(color: tempGrade['color'] as Color, fontSize: 20, fontWeight: FontWeight.w900)),
                        Text("배터리 ${_batteryTemp.toStringAsFixed(1)}°C", style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _buildTierChargingGauge(_batteryTemp),
                    const SizedBox(height: 4),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("D(13A)", style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                        Text("C(25A)", style: TextStyle(color: Color(0xFF2979FF), fontSize: 10, fontWeight: FontWeight.bold)),
                        Text("A(63A)", style: TextStyle(color: Color(0xFF00E5FF), fontSize: 10, fontWeight: FontWeight.bold)),
                        Text("S(120A)", style: TextStyle(color: Color(0xFF00E676), fontSize: 10, fontWeight: FontWeight.bold)),
                        Text("B(42A)", style: TextStyle(color: Color(0xFFFF9100), fontSize: 10, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                ),
                const Divider(color: Colors.white10, height: 12),
                // 게이지 바 없이 크고 시원한 텍스트로만 구성
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A212B),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("평생 총 누적 충전", style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold)),
                      Text("${_totalCumulativeChargeKwh.toStringAsFixed(1)} kWh", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 19, fontWeight: FontWeight.w900)),
                    ],
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: const Color(0xFF1A212B), borderRadius: BorderRadius.circular(8)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("평생 완충 횟수", style: TextStyle(color: Colors.white54, fontSize: 12)),
                            const SizedBox(height: 2),
                            Text("$_chargeTimesCount 회", style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: const Color(0xFF1A212B), borderRadius: BorderRadius.circular(8)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("과방전 차단", style: TextStyle(color: Colors.white54, fontSize: 12)),
                            const SizedBox(height: 2),
                            Text("$_dischargeTimesCount 회", style: TextStyle(color: _dischargeTimesCount > 0 ? const Color(0xFFFF5252) : const Color(0xFF00E676), fontSize: 18, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 33,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF13171D),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF222A35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.shield_outlined, color: Color(0xFFFFB300), size: 20),
                    SizedBox(width: 6),
                    Text("고전압 안전 & 기밀 진단", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        const Text("고전압 팩 절연 저항", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                        Text("$_insulationResistanceKohm kΩ", style: TextStyle(color: _insulationResistanceKohm > 500 ? const Color(0xFF00E676) : const Color(0xFFFF5252), fontSize: 20, fontWeight: FontWeight.w900)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _buildInsulationGauge(_insulationResistanceKohm),
                    const SizedBox(height: 3),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("0 (위험)", style: TextStyle(color: Colors.redAccent, fontSize: 10)),
                        Text("500kΩ (기준선)", style: TextStyle(color: Colors.amber, fontSize: 10)),
                        Text("5000kΩ (최상)", style: TextStyle(color: Color(0xFF00E676), fontSize: 10)),
                      ],
                    ),
                  ],
                ),
                const Divider(color: Colors.white10, height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFF1A212B), borderRadius: BorderRadius.circular(10)),
                  child: Column(
                    children: [
                      _buildBigStatusRow("메인 안전 스위치(DC)", _isDcSwitchClosed ? "정상 체결 (LOCK)" : "개방 주의", _isDcSwitchClosed ? const Color(0xFF00E676) : const Color(0xFFFF5252)),
                      const Divider(color: Colors.white10, height: 12),
                      _buildBigStatusRow("배터리 팩 커버 밀폐", _isPackCoverClosed ? "정상 밀폐 (OK)" : "점검 필요", _isPackCoverClosed ? const Color(0xFF00E676) : const Color(0xFFFF5252)),
                      const Divider(color: Colors.white10, height: 12),
                      _buildBigStatusRow("내부 침수/수분 센서", _isWaterAlarm ? "⚠️ 수분 감지 경고" : "정상 (건조)", _isWaterAlarm ? const Color(0xFFFF5252) : const Color(0xFF00E676)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 34,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF13171D),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF222A35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.tune, color: Color(0xFF00E5FF), size: 20),
                        SizedBox(width: 6),
                        Text("셀 밸런싱 정밀 모니터", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
                      decoration: BoxDecoration(color: (cellBal['color'] as Color).withOpacity(0.2), borderRadius: BorderRadius.circular(6)),
                      child: Text("${cellBal['status']}", style: TextStyle(color: cellBal['color'] as Color, fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        const Text("셀 간 최대 전압 편차", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                        Text("$_cellDeltaMv mV", style: TextStyle(color: cellBal['color'] as Color, fontSize: 24, fontWeight: FontWeight.w900)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _buildCellBalanceGauge(_cellDeltaMv),
                    const SizedBox(height: 3),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("0mV (최적)", style: TextStyle(color: Color(0xFF00E676), fontSize: 10, fontWeight: FontWeight.bold)),
                        Text("25mV", style: TextStyle(color: Color(0xFF00E5FF), fontSize: 10)),
                        Text("50mV", style: TextStyle(color: Color(0xFFFFD600), fontSize: 10)),
                        Text("80mV+ (점검)", style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                ),
                const Divider(color: Colors.white10, height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFF1A212B), borderRadius: BorderRadius.circular(10)),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("최고 전압 셀", style: TextStyle(color: Colors.white70, fontSize: 13)),
                          Text("#$_cellMaxId번 ($_cellMaxMv mV)", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 15, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("최저 전압 셀", style: TextStyle(color: Colors.white70, fontSize: 13)),
                          Text("#$_cellMinId번 ($_cellMinMv mV)", style: const TextStyle(color: Color(0xFFFF9100), fontSize: 15, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBigStatusRow(String title, String status, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        Text(status, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildTierChargingGauge(double temp) {
    return LayoutBuilder(
      builder: (context, constraints) {
        double w = constraints.maxWidth;
        double pinRatio = ((temp + 10.0) / 70.0).clamp(0.0, 1.0);
        double pinPos = pinRatio * (w - 6.0);

        return SizedBox(
          height: 16,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerLeft,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Row(
                  children: [
                    Expanded(flex: 14, child: Container(color: const Color(0xFFFF5252))),
                    Expanded(flex: 14, child: Container(color: const Color(0xFF2979FF))),
                    Expanded(flex: 14, child: Container(color: const Color(0xFF00E5FF))),
                    Expanded(flex: 43, child: Container(color: const Color(0xFF00E676))),
                    Expanded(flex: 15, child: Container(color: const Color(0xFFFF9100))),
                  ],
                ),
              ),
              Positioned(
                left: pinPos,
                child: Container(
                  width: 6,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(3),
                    boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 4, offset: Offset(0, 1))],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInsulationGauge(int isoKohm) {
    return LayoutBuilder(
      builder: (context, constraints) {
        double w = constraints.maxWidth;
        double pinRatio = (isoKohm / 5000.0).clamp(0.0, 1.0);
        double pinPos = pinRatio * (w - 6.0);

        return SizedBox(
          height: 14,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerLeft,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Row(
                  children: [
                    Expanded(flex: 15, child: Container(color: Colors.redAccent)),
                    Expanded(flex: 15, child: Container(color: Colors.amber)),
                    Expanded(flex: 70, child: Container(color: const Color(0xFF00E676))),
                  ],
                ),
              ),
              Positioned(
                left: pinPos,
                child: Container(
                  width: 6,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(3),
                    boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 4)],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCellBalanceGauge(int deltaMv) {
    return LayoutBuilder(
      builder: (context, constraints) {
        double w = constraints.maxWidth;
        double pinRatio = (deltaMv / 120.0).clamp(0.0, 1.0);
        double pinPos = pinRatio * (w - 6.0);

        return SizedBox(
          height: 14,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerLeft,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Row(
                  children: [
                    Expanded(flex: 25, child: Container(color: const Color(0xFF00E676))),
                    Expanded(flex: 25, child: Container(color: const Color(0xFF00E5FF))),
                    Expanded(flex: 30, child: Container(color: const Color(0xFFFFD600))),
                    Expanded(flex: 40, child: Container(color: const Color(0xFFFF5252))),
                  ],
                ),
              ),
              Positioned(
                left: pinPos,
                child: Container(
                  width: 6,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(3),
                    boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 4)],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // =========================================================================
  // [캠핑 모드 대시보드] (초대형 폰트 & 46px 극대화 세로 배터리 바)
  // =========================================================================
  Widget _buildCampingDashboard() {
    bool isCharging = _chargePowerKw > 0.3;
    bool isFastCharge = _chargePowerKw > 10.0;
    double liveWatts = (_voltage * _current).abs();
    if (liveWatts > 65000) liveWatts = 0.0;
    double percentPerHour = liveWatts > 0 ? (liveWatts / (_batteryTotalKwh * 1000)) * 100 : 0.0;

    String margin20Time = _calculateCampingRemainingTime(20.0);
    String margin0Time = _calculateCampingRemainingTime(0.0);
    String avail20Kwh = ((_soc - 20).clamp(0, 100) * _batteryTotalKwh / 100).toStringAsFixed(1);
    String avail0Kwh = (_soc * _batteryTotalKwh / 100).toStringAsFixed(1);

    return Row(
      children: [
        // 좌측: 초대형 46px 배터리 바 + 74px 잔량 폰트 + 공조 3종
        Expanded(
          flex: 45,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF13171D),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFFFB300).withOpacity(0.5), width: 1.2),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.battery_charging_full, color: Color(0xFF00E676), size: 24),
                        SizedBox(width: 8),
                        Text("배터리 잔량", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: const Color(0xFFFFB300).withOpacity(0.2), borderRadius: BorderRadius.circular(6)),
                      child: Text(
                        isCharging ? "충전 진행 중" : "무시동 방전 중",
                        style: const TextStyle(color: Color(0xFFFFB300), fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6.0),
                    child: Row(
                      children: [
                        // 매우 두꺼운 46px 세로형 배터리 바
                        Container(
                          width: 46,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E242C),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white30, width: 1.5),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              double fillHeight = constraints.maxHeight * (_soc / 100.0).clamp(0.0, 1.0);
                              return Align(
                                alignment: Alignment.bottomCenter,
                                child: Container(
                                  width: 46,
                                  height: fillHeight,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: _soc <= 20
                                          ? [const Color(0xFFFF5252), const Color(0xFFFF9100)]
                                          : [const Color(0xFF00E5FF), const Color(0xFF00E676)],
                                      begin: Alignment.bottomCenter,
                                      end: Alignment.topCenter,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 16),
                        // 74px 초대형 배터리 잔량 & 실시간 전력 소모
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    _soc.toStringAsFixed(1),
                                    style: const TextStyle(
                                      color: Color(0xFF00E676),
                                      fontSize: 74,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -3.0,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Text("%", style: TextStyle(color: Color(0xFF00E676), fontSize: 28, fontWeight: FontWeight.bold)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(isCharging ? "실시간 충전 전력" : "실시간 소모 전력", style: const TextStyle(color: Colors.white60, fontSize: 13)),
                                      const SizedBox(height: 2),
                                      Text(isCharging ? "${_chargePowerKw.toStringAsFixed(1)} kW" : "${liveWatts.toStringAsFixed(0)} W", style: const TextStyle(color: Color(0xFFFFB300), fontSize: 24, fontWeight: FontWeight.w900)),
                                    ],
                                  ),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(isCharging ? "시간당 충전율" : "시간당 소모율", style: const TextStyle(color: Colors.white60, fontSize: 13)),
                                      const SizedBox(height: 2),
                                      Text("${percentPerHour.toStringAsFixed(1)} %/h", style: const TextStyle(color: Colors.cyanAccent, fontSize: 24, fontWeight: FontWeight.w900)),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A212B),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildCampingTempItem(title: "🌡️ 외기온도", valueText: "${_envTemp.toStringAsFixed(1)}°C", valueColor: Colors.orangeAccent),
                      Container(width: 1, height: 28, color: Colors.white24),
                      _buildCampingTempItem(title: "❄️ 에어컨", valueText: "${_evapTemp.toStringAsFixed(1)}°C", valueColor: const Color(0xFF00E5FF)),
                      Container(width: 1, height: 28, color: Colors.white24),
                      _buildCampingTempItem(title: "🔥 히터 PTC", valueText: "${_ptcTemp.toStringAsFixed(1)}°C", valueColor: Colors.redAccent),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 우측: 무시동 공조 가용 시간 & 실시간 충전 대기 (34px 초대형 폰트)
        Expanded(
          flex: 55,
          child: Column(
            children: [
              Expanded(
                flex: 50,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF13171D),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF222A35)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text("🏕️ 무시동 공조 가용 시간 (배터리 한계 마진)", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                          Text("실시간 소모율 반영", style: TextStyle(color: Colors.white38, fontSize: 12)),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E242C),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.5), width: 1.2),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("🛡️ 복귀 마진 (20% 도달)", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 4),
                                  Text(margin20Time, style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -1.0)),
                                  Text("가용량: $avail20Kwh kWh", style: const TextStyle(color: Colors.white54, fontSize: 13)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E242C),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: const Color(0xFFFF5252).withOpacity(0.5), width: 1.2),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("⚠️ 한계 마진 (0% 방전)", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 4),
                                  Text(margin0Time, style: const TextStyle(color: Color(0xFFFF5252), fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -1.0)),
                                  Text("잔여량: $avail0Kwh kWh", style: const TextStyle(color: Colors.white54, fontSize: 13)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                flex: 50,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF13171D),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: isCharging ? const Color(0xFF00E5FF).withOpacity(0.6) : const Color(0xFF222A35)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isCharging ? (isFastCharge ? "⚡ 급속 충전 진행 중" : "🔌 완속 충전 진행 중") : "⚡ 실시간 충전 대기",
                            style: TextStyle(color: isCharging ? const Color(0xFFFFB300) : Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          Text("${_chargePowerKw.toStringAsFixed(1)} kW", style: TextStyle(color: isCharging ? const Color(0xFFFFB300) : Colors.white54, fontSize: 22, fontWeight: FontWeight.w900)),
                        ],
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E242C),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("80% 목표 도달", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 4),
                                  Text(_calculateTimeToSoc(80.0), style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -1.0)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E242C),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: const Color(0xFF00E676).withOpacity(0.4)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("100% 완전 충전", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 4),
                                  Text(_calculateTimeToSoc(100.0), style: const TextStyle(color: Color(0xFF00E676), fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -1.0)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCampingTempItem({required String title, required String valueText, required Color valueColor}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: const TextStyle(color: Colors.white60, fontSize: 13)),
        const SizedBox(height: 2),
        Text(valueText, style: TextStyle(color: valueColor, fontSize: 17, fontWeight: FontWeight.bold)),
      ],
    );
  }

  // =========================================================================
  // [하단 1열 통합 바]
  // =========================================================================
  Widget _buildBottomSingleUnifiedBar() {
    Map<String, dynamic> tempGrade = _getBatteryTempGrade();
    double totalConsumedKwh = _energyDriveKwh + _energyPtcKwh + _energyAcKwh + _energyStandbyKwh;
    double consumedPct = (_batteryTotalKwh > 0) ? (totalConsumedKwh / _batteryTotalKwh) * 100.0 : 0.0;
    
    bool isCharging = _chargePowerKw > 0.3 || _current < -0.5;
    double liveWatts = (_voltage * _current).abs();
    if (liveWatts > 65000) liveWatts = 0.0;

    String powerTitle = isCharging ? "실시간 충전 전력" : "실시간 소모 전력";
    String powerValue = isCharging ? "+${_chargePowerKw.toStringAsFixed(1)} kW" : "${liveWatts.toStringAsFixed(0)} W";
    String powerSub = isCharging ? "충전 진행 중" : (liveWatts > 1000 ? "소모 높음" : "정상 소모");
    Color powerColor = isCharging ? const Color(0xFF00E676) : (liveWatts > 1000 ? const Color(0xFFFFB300) : Colors.white);

    return Row(
      children: [
        _buildUnifiedBottomCard("운행시간 · 거리", "${_accumulatedRealTripKm.toStringAsFixed(1)} km", subText: _formatDrivingTime(_drivingSeconds), valueColor: const Color(0xFF00E5FF)),
        _buildUnifiedBottomCard("이번 주행 소모량", "${totalConsumedKwh.toStringAsFixed(1)} kWh", subText: "(-${consumedPct.toStringAsFixed(1)}%)", valueColor: const Color(0xFFFFB300)),
        _buildUnifiedBottomCard(powerTitle, powerValue, subText: powerSub, valueColor: powerColor),
        _buildUnifiedBottomCard("셀 편차(ΔV)", "$_cellDeltaMv mV", subText: "#$_cellMaxId vs #$_cellMinId", valueColor: _cellDeltaMv <= 30 ? const Color(0xFF00E676) : const Color(0xFFFF5252)),
        _buildUnifiedBottomCard("배터리 온도", "${_batteryTemp.toStringAsFixed(1)}°C", subText: "${tempGrade['grade']} (${tempGrade['amp']})", valueColor: tempGrade['color'] as Color),
      ],
    );
  }

  Widget _buildUnifiedBottomCard(String title, String mainValue, {required String subText, required Color valueColor}) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2.0),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF13171D),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFF222A35)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.w500)),
            const SizedBox(height: 1),
            Text(mainValue, style: TextStyle(color: valueColor, fontSize: 14, fontWeight: FontWeight.bold)),
            Text(subText, style: const TextStyle(color: Colors.white38, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// [CustomPainter] 메인 화면 상단 반원 아크 게이지
// =========================================================================
class _ArcPowerMeterPainter extends CustomPainter {
  final double powerKw;
  final double safeLimitKw;
  final double avgPowerKw;

  _ArcPowerMeterPainter({
    required this.powerKw,
    required this.safeLimitKw,
    required this.avgPowerKw,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2.0, size.height / 2.0);
    final radius = size.width / 2.0 - 12.0;
    const strokeWidth = 16.0;

    final bgPaint = Paint()
      ..color = const Color(0xFF1E242C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      math.pi,
      math.pi,
      false,
      bgPaint,
    );

    final centerTickPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3.0;
    canvas.drawLine(
      Offset(center.dx, center.dy - radius - 11),
      Offset(center.dx, center.dy - radius + 11),
      centerTickPaint,
    );

    final double powerMag = powerKw.abs().clamp(0.0, 50.0);
    final double sweepAngle = (powerMag / 50.0) * (math.pi / 2.0);

    if (powerKw > 0.1) {
      Color barColor = const Color(0xFF00E676);
      if (powerKw > safeLimitKw) {
        barColor = const Color(0xFFFF5252);
      } else if (powerKw > safeLimitKw * 0.75) {
        barColor = const Color(0xFFFFB300);
      }

      final powerPaint = Paint()
        ..color = barColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2.0,
        sweepAngle,
        false,
        powerPaint,
      );
    } else if (powerKw < -0.1) {
      final regenPaint = Paint()
        ..color = const Color(0xFF00E5FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2.0,
        -sweepAngle,
        false,
        regenPaint,
      );
    }

    final double limitRatio = (safeLimitKw / 50.0).clamp(0.0, 1.0);
    final double limitAngle = -math.pi / 2.0 + (limitRatio * (math.pi / 2.0));
    final limitPinPaint = Paint()
      ..color = const Color(0xFFFF5252)
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    final limitP1 = Offset(center.dx + (radius - 12) * math.cos(limitAngle), center.dy + (radius - 12) * math.sin(limitAngle));
    final limitP2 = Offset(center.dx + (radius + 12) * math.cos(limitAngle), center.dy + (radius + 12) * math.sin(limitAngle));
    canvas.drawLine(limitP1, limitP2, limitPinPaint);

    if (avgPowerKw > 0.5) {
      final double avgRatio = (avgPowerKw / 50.0).clamp(0.0, 1.0);
      final double avgAngle = -math.pi / 2.0 + (avgRatio * (math.pi / 2.0));
      final avgPinPaint = Paint()
        ..color = const Color(0xFF00E5FF)
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round;

      final avgP1 = Offset(center.dx + (radius - 10) * math.cos(avgAngle), center.dy + (radius - 10) * math.sin(avgAngle));
      final avgP2 = Offset(center.dx + (radius + 10) * math.cos(avgAngle), center.dy + (radius + 10) * math.sin(avgAngle));
      canvas.drawLine(avgP1, avgP2, avgPinPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ArcPowerMeterPainter oldDelegate) {
    return oldDelegate.powerKw != powerKw ||
        oldDelegate.safeLimitKw != safeLimitKw ||
        oldDelegate.avgPowerKw != avgPowerKw;
  }
}
