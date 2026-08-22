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

  // 실시간 악셀 & 공조 3종 온도 데이터
  int _accelPedalPct = 0;
  double _ptcTemp = 20.0;
  double _evapTemp = 15.0;
  double _envTemp = 25.0;

  // 배터리 평생 통계 & 관리 데이터
  double _totalCumulativeChargeKwh = 0.0;
  double _totalRegenEnergyKwh = 0.0;
  double _totalDischargeEnergyKwh = 0.0;
  int _chargeTimesCount = 0;
  int _dischargeTimesCount = 0;

  // 고전압 릴레이 4종 수명 카운터
  int _rlyPreChgCount = 0;
  int _rlyMainPosCount = 0;
  int _rlyMainNegCount = 0;
  int _rlyFastChgCount = 0;

  // 절연저항 & 안전 스위치
  int _insulationResistanceKohm = 5000;
  bool _isDcSwitchClosed = true;
  bool _isPackCoverClosed = true;

  // 최고/최저 셀 번호 & 내부저항(DC-IR)
  int _cellMaxId = 1;
  int _cellMinId = 1;
  double _cellDcIrMax = 0.0;
  double _cellDcIrMin = 0.0;

  // SOC 구간별 충전 횟수 (10개 구간)
  final List<int> _socChargeCounts = List.filled(10, 0);

  int _cellMaxMv = 3315;
  int _cellMinMv = 3300;
  int _cellDeltaMv = 15;

  final List<_DrivingSample> _recent1MinSamples = [];
  double _recent1MinEfficiency = 5.7;
  int _efficiencyScore = 50;

  double _pureDriveEnergyKwh = 0.0;
  double _pureDriveDistanceKm = 0.0;
  double _pureDriveTripEfficiency = 5.7;

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

    // 1. BMS_VCU_0 (0x0CFF7D03)
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

    // 2. BMS_VCU_1 (0x0CFF7E03)
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

    // 3. BMS_VCU_2 (0x0CFF7F03): 절연저항
    if (id == 0x0CFF7F03) {
      _insulationResistanceKohm = ((d[7] << 8) | d[6]) * 10;
      if (mounted) setState(() {});
      return true;
    }

    // 4. VCU_Meter (0x19014801 / 0x18FF50E5 / 0x18FFDC01)
    if (id == 0x19014801 || id == 0x18FF50E5 || id == 0x18FFDC01 || id == 0x09014801) {
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

      int rawEnv = d[5];
      if (rawEnv >= 0 && rawEnv <= 255) {
        _envTemp = (rawEnv - 50).toDouble();
      }

      int rawEvap = d[6];
      if (rawEvap >= 0 && rawEvap <= 255) {
        _evapTemp = (rawEvap - 50).toDouble();
      }

      int rawPtc = d[7];
      if (rawPtc >= 0 && rawPtc <= 255) {
        _ptcTemp = (rawPtc - 50).toDouble();
      }

      if (mounted) setState(() {});
      return true;
    }

    // 5. Meter_VCU_1 (0x190048D5 / 0x18FEDCD5)
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

    // 6. BMS_VCU_4 (0x0CFF8103): 수분센서 & DC/Pack 스위치
    if (id == 0x0CFF8103) {
      _isWaterAlarm = (d[6] & 0x01) != 0;
      _isDcSwitchClosed = (d[6] & 0x04) != 0;
      _isPackCoverClosed = (d[6] & 0x08) != 0;
      if (mounted) setState(() {});
      return true;
    }

    // 7. BMS_VCU_3 (0x0CFF8003): 완충 횟수 및 과방전 횟수
    if (id == 0x0CFF8003) {
      _chargeTimesCount = (d[3] << 8) | d[2];
      _dischargeTimesCount = (d[5] << 8) | d[4];
      if (mounted) setState(() {});
      return true;
    }

    // 8. BMS_VCU_7_1 (0x0CFF8503): 평생 누적 충전량
    if (id == 0x0CFF8503 || id == 0x0CFF8501) {
      int rawCumul = (d[5] << 24) | (d[4] << 16) | (d[3] << 8) | d[2];
      if (rawCumul > 0) {
        _totalCumulativeChargeKwh = rawCumul * 0.1;
      }
      if (mounted) setState(() {});
      return true;
    }

    // 9. BMS_VCU_T37_CumulativeEnergy (0x2365563651): 누적 회생 및 누적 방전량
    if (id == 0x2365563651 || id == 0x0CFF8703) {
      int rawRegen = (d[3] << 24) | (d[2] << 16) | (d[1] << 8) | d[0];
      int rawDchg = (d[7] << 24) | (d[6] << 16) | (d[5] << 8) | d[4];
      if (rawRegen > 0) _totalRegenEnergyKwh = rawRegen * 0.1;
      if (rawDchg > 0) _totalDischargeEnergyKwh = rawDchg * 0.1;
      if (mounted) setState(() {});
      return true;
    }

    // 10. BMS_VCU_T38_HvRelayOpCount (0x2365563907): 릴레이 4종 수명 카운터
    if (id == 0x2365563907 || id == 0x0CFF8B03) {
      _rlyPreChgCount = (d[1] << 8) | d[0];
      _rlyMainNegCount = (d[3] << 8) | d[2];
      _rlyMainPosCount = (d[5] << 8) | d[4];
      _rlyFastChgCount = (d[7] << 8) | d[6];
      if (mounted) setState(() {});
      return true;
    }

    // 11. BMS_VCU_T39_CellDcIR (0x2365564163): 셀 내부저항
    if (id == 0x2365564163 || id == 0x0CFF8C03) {
      _cellDcIrMax = ((d[1] << 8) | d[0]) * 0.1;
      _cellDcIrMin = ((d[3] << 8) | d[2]) * 0.1;
      if (mounted) setState(() {});
      return true;
    }

    // 12. SOC 구간별 충전 횟수 (T33, T34, T35)
    if (id == 0x0CFF8803 || id == 0x2365562627) {
      _socChargeCounts[0] = (d[1] << 8) | d[0];
      _socChargeCounts[1] = (d[3] << 8) | d[2];
      _socChargeCounts[2] = (d[5] << 8) | d[4];
      _socChargeCounts[3] = (d[7] << 8) | d[6];
      if (mounted) setState(() {});
      return true;
    }
    if (id == 0x0CFF8903 || id == 0x2365562883) {
      _socChargeCounts[4] = (d[1] << 8) | d[0];
      _socChargeCounts[5] = (d[3] << 8) | d[2];
      _socChargeCounts[6] = (d[5] << 8) | d[4];
      _socChargeCounts[7] = (d[7] << 8) | d[6];
      if (mounted) setState(() {});
      return true;
    }
    if (id == 0x0CFF8A03 || id == 0x2365563139) {
      _socChargeCounts[8] = (d[1] << 8) | d[0];
      _socChargeCounts[9] = (d[3] << 8) | d[2];
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
    double speed = _realVehicleSpeedKmh > 0.5 ? _realVehicleSpeedKmh : (_powerKw > 1.0 ? (_powerKw * 4.5).clamp(10.0, 100.0) : 0.0);

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
    if (powerKw < 0) return const Color(0xFF00E5FF);
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

  // 배터리 관리 & 평생 이력 전문 다이얼로그
  void _showBatteryManagementDialog() {
    int maxChgCnt = _socChargeCounts.reduce((a, b) => a > b ? a : b);
    if (maxChgCnt == 0) maxChgCnt = 1;

    final socLabels = ["0~10%", "11~20%", "21~30%", "31~40%", "41~50%", "51~60%", "61~70%", "71~80%", "81~90%", "91~100%"];

    showDialog(
      context: context,
      builder: (BuildContext ctx) {
        return Dialog(
          backgroundColor: const Color(0xFF13171D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF00E5FF), width: 1.2),
          ),
          child: Container(
            width: 780,
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.tune, color: Color(0xFF00E5FF), size: 22),
                          SizedBox(width: 8),
                          Text(
                            "배터리 시스템 정밀 진단 및 평생 이력 관리",
                            style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 12),
                  
                  // 1. 평생 누적 에너지 통계
                  const Text("🔋 평생 누적 에너지 통계 (출고 후 영구 기록)", style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _buildModalStatCard("총 누적 충전량", "${_totalCumulativeChargeKwh.toStringAsFixed(1)} kWh", const Color(0xFF00E676)),
                      const SizedBox(width: 6),
                      _buildModalStatCard("평생 회생 발전량", "${_totalRegenEnergyKwh.toStringAsFixed(1)} kWh", const Color(0xFF00E5FF)),
                      const SizedBox(width: 6),
                      _buildModalStatCard("평생 방전 사용량", "${_totalDischargeEnergyKwh.toStringAsFixed(1)} kWh", const Color(0xFFFFB300)),
                      const SizedBox(width: 6),
                      _buildModalStatCard("완충 / 과방전", "$_chargeTimesCount / $_dischargeTimesCount회", _dischargeTimesCount > 0 ? const Color(0xFFFF5252) : Colors.white),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 2. 고전압 릴레이 수명 카운터 & 안전 절연 상태
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 50,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("⚡ 고전압 릴레이 접촉기 수명 카운터", style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white12)),
                              child: Column(
                                children: [
                                  _buildRelayRow("메인 양극(+) 릴레이", "$_rlyMainPosCount 회", Colors.white70),
                                  const Divider(color: Colors.white10, height: 8),
                                  _buildRelayRow("메인 음극(-) 릴레이", "$_rlyMainNegCount 회", Colors.white70),
                                  const Divider(color: Colors.white10, height: 8),
                                  _buildRelayRow("프리차지 릴레이", "$_rlyPreChgCount 회", Colors.white70),
                                  const Divider(color: Colors.white10, height: 8),
                                  _buildRelayRow("급속충전 릴레이", "$_rlyFastChgCount 회", const Color(0xFFFFB300)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 50,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("🛡️ 고전압 절연 & 셀 상세 위치", style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white12)),
                              child: Column(
                                children: [
                                  _buildRelayRow("팩 절연 저항", "$_insulationResistanceKohm kΩ", _insulationResistanceKohm > 500 ? const Color(0xFF00E676) : const Color(0xFFFF5252)),
                                  const Divider(color: Colors.white10, height: 8),
                                  _buildRelayRow("안전 인터록 스위치", _isDcSwitchClosed ? "정상 체결" : "개방(점검)", _isDcSwitchClosed ? const Color(0xFF00E676) : const Color(0xFFFF5252)),
                                  const Divider(color: Colors.white10, height: 8),
                                  _buildRelayRow("최고/최저 셀 번호", "#$_cellMaxId번 / #$_cellMinId번", const Color(0xFF00E5FF)),
                                  const Divider(color: Colors.white10, height: 8),
                                  _buildRelayRow("셀 내부저항(DC-IR)", "${_cellDcIrMin.toStringAsFixed(1)} ~ ${_cellDcIrMax.toStringAsFixed(1)} mΩ", Colors.white70),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 3. SOC 구간별 충전 히스토그램
                  const Text("📊 SOC 구간별 누적 충전 빈도 패턴", style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white12)),
                    child: Column(
                      children: List.generate(10, (idx) {
                        int count = _socChargeCounts[idx];
                        double barRatio = (count / maxChgCnt).clamp(0.0, 1.0);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1.5),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 60,
                                child: Text(socLabels[idx], style: const TextStyle(color: Colors.white54, fontSize: 10)),
                              ),
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: barRatio,
                                    backgroundColor: Colors.white10,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      idx >= 8 ? const Color(0xFF00E676) : (idx <= 1 ? const Color(0xFFFF5252) : const Color(0xFF00E5FF)),
                                    ),
                                    minHeight: 6,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 35,
                                child: Text("$count회", textAlign: TextAlign.right, style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                        );
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRelayRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        Text(value, style: TextStyle(color: valueColor, fontSize: 12, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildModalStatCard(String title, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1E242C),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(color: Colors.white54, fontSize: 10)),
            const SizedBox(height: 2),
            Text(value, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
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
              onTap: _showBatteryManagementDialog,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E242C),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.6), width: 1.2),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.tune, color: Color(0xFF00E5FF), size: 16),
                    SizedBox(width: 5),
                    Text(
                      "배터리 관리",
                      style: TextStyle(color: Color(0xFF00E5FF), fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
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
          flex: 45,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF13171D),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFFFB300).withOpacity(0.4)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("현재 배터리 잔량", style: TextStyle(color: Colors.white54, fontSize: 13)),
                Text(
                  "${_soc.toStringAsFixed(1)} %",
                  style: const TextStyle(color: Color(0xFF00E676), fontSize: 44, fontWeight: FontWeight.bold),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Column(
                      children: [
                        const Text("실시간 소모 전력", style: TextStyle(color: Colors.white54, fontSize: 12)),
                        const SizedBox(height: 2),
                        Text(
                          "${liveWatts.toStringAsFixed(0)} W",
                          style: const TextStyle(color: Color(0xFFFFB300), fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    Column(
                      children: [
                        const Text("시간당 소모율", style: TextStyle(color: Colors.white54, fontSize: 12)),
                        const SizedBox(height: 2),
                        Text(
                          "${percentPerHour.toStringAsFixed(1)} %/h",
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A212B),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildCampingTempItem(title: "🌡️ 외기", valueText: "${_envTemp.toStringAsFixed(1)}°C", valueColor: Colors.orangeAccent),
                      Container(width: 1, height: 22, color: Colors.white24),
                      _buildCampingTempItem(title: "❄️ 에어컨", valueText: "${_evapTemp.toStringAsFixed(1)}°C", valueColor: const Color(0xFF00E5FF)),
                      Container(width: 1, height: 22, color: Colors.white24),
                      _buildCampingTempItem(title: "🔥 히터PTC", valueText: "${_ptcTemp.toStringAsFixed(1)}°C", valueColor: Colors.redAccent),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 55,
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
              const SizedBox(height: 8),
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

  Widget _buildCampingTempItem({required String title, required String valueText, required Color valueColor}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        const SizedBox(height: 2),
        Text(valueText, style: TextStyle(color: valueColor, fontSize: 13, fontWeight: FontWeight.bold)),
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
              Text(title, style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w500)),
              Text(subInfo, style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            remainingTime,
            style: TextStyle(color: accentColor, fontSize: 34, fontWeight: FontWeight.bold),
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

  Widget _buildCenterSocGauge() {
    Color effThemeColor = _getEfficiencyColor(_efficiencyScore);
    double accelRatio = (_accelPedalPct / 100.0).clamp(0.0, 1.0);

    double ptcRatio = ((_ptcTemp - 15.0) / 65.0).clamp(0.0, 1.0);
    double acRatio = ((25.0 - _evapTemp) / 25.0).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF13171D),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF222A35)),
      ),
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF1E242C),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white24, width: 0.8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.thermostat_outlined, color: Colors.orangeAccent, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    "외기온도 ${_envTemp.toStringAsFixed(1)}°C",
                    style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                flex: 15,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("ACCEL", style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text("$_accelPedalPct%", style: const TextStyle(color: Color(0xFF00E676), fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Expanded(
                      child: Container(
                        width: 14,
                        decoration: BoxDecoration(
                          color: const Color(0xFF222A35),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                width: 14,
                                height: constraints.maxHeight * accelRatio,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00E676),
                                  borderRadius: BorderRadius.circular(7),
                                  boxShadow: const [
                                    BoxShadow(color: Color(0xFF00E676), blurRadius: 4, spreadRadius: 1),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text("0%", style: TextStyle(color: Colors.white30, fontSize: 10)),
                  ],
                ),
              ),
              Expanded(
                flex: 70,
                child: Center(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 250,
                        height: 250,
                        child: CircularProgressIndicator(
                          value: (_soc / 100.0).clamp(0.0, 1.0),
                          strokeWidth: 20,
                          backgroundColor: const Color(0xFF222A35),
                          valueColor: AlwaysStoppedAnimation<Color>(effThemeColor),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 10),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(_pureDriveTripEfficiency.toStringAsFixed(1), style: TextStyle(color: effThemeColor, fontSize: 26, fontWeight: FontWeight.bold)),
                              const SizedBox(width: 4),
                              Text("km/kWh", style: TextStyle(color: effThemeColor.withOpacity(0.85), fontSize: 16, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(_soc.toStringAsFixed(1), style: TextStyle(color: effThemeColor, fontSize: 58, fontWeight: FontWeight.bold)),
                              Text("%", style: TextStyle(color: effThemeColor, fontSize: 24, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 15,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("히터PTC", style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                    Text("${_ptcTemp.toStringAsFixed(0)}°C", style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Container(
                        width: 14,
                        decoration: BoxDecoration(
                          color: const Color(0xFF222A35),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            double halfHeight = constraints.maxHeight / 2.0;
                            return Stack(
                              children: [
                                Align(
                                  alignment: Alignment.center,
                                  child: Container(width: 14, height: 2, color: Colors.white54),
                                ),
                                Positioned(
                                  bottom: halfHeight,
                                  left: 0,
                                  right: 0,
                                  child: Container(
                                    height: halfHeight * ptcRatio,
                                    decoration: const BoxDecoration(
                                      color: Colors.redAccent,
                                      borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: halfHeight,
                                  left: 0,
                                  right: 0,
                                  child: Container(
                                    height: halfHeight * acRatio,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF00E5FF),
                                      borderRadius: BorderRadius.vertical(bottom: Radius.circular(7)),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text("${_evapTemp.toStringAsFixed(0)}°C", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 12, fontWeight: FontWeight.bold)),
                    const Text("에어컨", style: TextStyle(color: Color(0xFF00E5FF), fontSize: 10, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

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
                    Text("회생 ${regenKw.toStringAsFixed(1)}kW", style: TextStyle(color: regenKw > 0.1 ? const Color(0xFF00E5FF) : Colors.white54, fontSize: 17, fontWeight: FontWeight.bold)),
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

  // 중앙 0kW 영점 분할 파워바 (좌: 사이언 회생, 우: 가속출력)
  Widget _buildPowerBar() {
    double safeLimitKw = _getSafePowerLimitKw(_batteryTemp);
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
                  const Text("◀ 회생제동 (REGEN)", style: TextStyle(color: Color(0xFF00E5FF), fontSize: 13, fontWeight: FontWeight.bold)),
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
                  Text("실시간: ${_powerKw.toStringAsFixed(1)} kW", style: TextStyle(color: _powerKw < -0.1 ? const Color(0xFF00E5FF) : dynamicBarColor, fontSize: 15, fontWeight: FontWeight.bold)),
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
              double halfWidth = barWidth / 2.0;

              double powerMagnitude = _powerKw.abs().clamp(0.0, 50.0);
              double fillWidth = (powerMagnitude / 50.0) * halfWidth;

              double limitNormalized = (safeLimitKw / 50.0).clamp(0.0, 1.0);
              double pinLeft = halfWidth + (halfWidth * limitNormalized) - 4.0;

              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    width: barWidth,
                    height: 12,
                    decoration: BoxDecoration(
                      color: const Color(0xFF222A35),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  if (_powerKw < -0.1)
                    Positioned(
                      right: halfWidth,
                      child: Container(
                        width: fillWidth,
                        height: 12,
                        decoration: const BoxDecoration(
                          color: Color(0xFF00E5FF),
                          borderRadius: BorderRadius.horizontal(left: Radius.circular(6)),
                        ),
                      ),
                    )
                  else if (_powerKw > 0.1)
                    Positioned(
                      left: halfWidth,
                      child: Container(
                        width: fillWidth,
                        height: 12,
                        decoration: BoxDecoration(
                          color: dynamicBarColor,
                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
                        ),
                      ),
                    ),
                  Positioned(
                    left: halfWidth - 1.0,
                    child: Container(
                      width: 2.0,
                      height: 16,
                      color: Colors.white70,
                    ),
                  ),
                  Positioned(
                    left: pinLeft.clamp(halfWidth, barWidth - 8.0),
                    child: Container(
                      width: 8,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(2.0),
                        boxShadow: const [
                          BoxShadow(color: Colors.black87, blurRadius: 3, offset: Offset(0, 1)),
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
    Map<String, dynamic> tempGrade = _getBatteryTempGrade();
    double totalConsumedKwh = _driveEnergyKwh + _hvacEnergyKwh;
    double consumedPct = (_batteryTotalKwh > 0) ? (totalConsumedKwh / _batteryTotalKwh) * 100.0 : 0.0;
    double liveConsumeWatts = (_voltage * _current).abs();
    if (liveConsumeWatts > 65000) liveConsumeWatts = 0.0;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildBottomCard(
          title: "운행시간 · 이번주행",
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(_accumulatedRealTripKm.toStringAsFixed(1), style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 2),
                  const Text("km", style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 1),
              Text(_formatDrivingTime(_drivingSeconds), style: const TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
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
