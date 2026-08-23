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
  int _efficiencyScore = 50;

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

    if (id == 0x0CFF7F03) {
      int rawIso = (d[7] << 8) | d[6];
      if (rawIso > 0) _insulationResistanceKohm = rawIso * 10;
      if (mounted) setState(() {});
      return true;
    }

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

      _isFootBrakePressed = (d[4] & 0x01) != 0;

      if (mounted) setState(() {});
      return true;
    }

    if (id == 0x190048D5 || id == 0x18FEDCD5 || id == 0x090048D5) {
      double rawSpd = d[0].toDouble();
      _realVehicleSpeedKmh = (rawSpd > 140.0) ? rawSpd * 0.5 : rawSpd;
      if (mounted) setState(() {});
      return true;
    }

    if (id == 0x0CFF8103) {
      _isWaterAlarm = (d[6] & 0x01) != 0;
      _isDcSwitchClosed = (d[6] & 0x04) != 0;
      _isPackCoverClosed = (d[6] & 0x08) != 0;
      if (mounted) setState(() {});
      return true;
    }

    if (id == 0x0CFF8003) {
      _chargeTimesCount = (d[3] << 8) | d[2];
      _dischargeTimesCount = (d[5] << 8) | d[4];
      if (mounted) setState(() {});
      return true;
    }

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
    if (_realVehicleSpeedKmh > 0.5) {
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
          _recent1MinEfficiency = (totalDistanceKm / totalNetKwh).clamp(2.0, 10.0);
        }
      }

      double rawScore = ((_recent1MinEfficiency - 3.7) / (7.7 - 3.7)) * 100.0;
      _efficiencyScore = rawScore.clamp(0.0, 100.0).round();
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
    else if (t >= 10.0 && t < 15.0) return {'grade': 'A(저온)', 'amp': '63A', 'color': const Color(0xFF00E5FF), 'desc': '저온 감발'};
    else if (t > 45.0 && t <= 48.0) return {'grade': 'A(고온)', 'amp': '63A', 'color': const Color(0xFFFFD600), 'desc': '고온 진입'};
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
  // [1페이지] 메인 운전 대시보드 (여백 없이 꽉 찬 완벽 밸런스)
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

  // [좌측] 유류비 절감 전용 카드 (파란색 게이지 제거, 초대형 폰트 적용)
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

  // [중앙] 원형 SOC 게이지 + 상단 반원 아크 (화면 가득 꽉 채움)
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
              // 좌측 악셀 바
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
              // 중앙 초대형 통합 게이지
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
              // 우측 공조 바
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

  // [우측] 주행 효율 점수(초대형 폰트) + 에너지 소비처 4분할 두툼한 세로형 바
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
                  Icon(Icons.bolt, color: Color(0xFF00E676), size: 20),
                  SizedBox(width: 6),
                  Text("효율 & 에너지 분석", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                decoration: BoxDecoration(
                  color: isStopped ? Colors.white10 : effThemeColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: isStopped ? Colors.white24 : effThemeColor, width: 0.8),
                ),
                child: Text(
                  isStopped ? "⏸️ 대기" : "원페달 $_onePedalScorePct%",
                  style: TextStyle(color: isStopped ? Colors.white70 : effThemeColor, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              children: [
                // 좌측: 초대형 주행 점수 & 범례
                Expanded(
                  flex: 68,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text("$_efficiencyScore", style: TextStyle(color: effThemeColor, fontSize: 52, fontWeight: FontWeight.w900, letterSpacing: -1.5)),
                          const SizedBox(width: 4),
                          const Text("점", style: TextStyle(color: Colors.white70, fontSize: 20, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _buildVerticalLegendItem("구동 모터", const Color(0xFF00E676), "${dist['drive']}%"),
                      const SizedBox(height: 4),
                      _buildVerticalLegendItem("히터 PTC", Colors.redAccent, "${dist['ptc']}%"),
                      const SizedBox(height: 4),
                      _buildVerticalLegendItem("에어컨 A/C", Colors.cyanAccent, "${dist['ac']}%"),
                      const SizedBox(height: 4),
                      _buildVerticalLegendItem("전장 대기", Colors.white54, "${dist['stdby']}%"),
                    ],
                  ),
                ),
                // 우측: 두툼한 세로형 4분할 에너지 소비 바
                Expanded(
                  flex: 32,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E242C),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white10),
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
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(title, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        const Spacer(),
        Text(pct, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
      ],
    );
  }

  // =========================================================================
  // [2페이지] 슬라이딩 배터리 & BMS 정밀 분석 센터
  // =========================================================================
  Widget _buildBatteryDiagnosticsPage() {
    Map<String, dynamic> cellBal = _getCellBalanceStatus();
    Map<String, dynamic> tempGrade = _getBatteryTempGrade();

    return Row(
      children: [
        // 1단: 평생 누적 이력 & 안전 인터록
        Expanded(
          flex: 33,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF222A35))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.history_edu_outlined, color: Color(0xFF00E5FF), size: 18),
                    SizedBox(width: 6),
                    Text("배터리 평생 실측 이력", style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
                _buildDiagRow("평생 총 누적 충전량", "${_totalCumulativeChargeKwh.toStringAsFixed(1)} kWh", const Color(0xFF00E676)),
                _buildDiagRow("평생 누적 완충 횟수", "$_chargeTimesCount 회", const Color(0xFF00E5FF)),
                _buildDiagRow("과방전 차단 보호 이력", "$_dischargeTimesCount 회", _dischargeTimesCount > 0 ? const Color(0xFFFF5252) : const Color(0xFF00E676)),
                const Divider(color: Colors.white12, height: 12),
                _buildDiagRow("배터리 건강 상태 (SOH)", "$_soh %", const Color(0xFF00E676)),
                _buildDiagRow("급속 충전 허용 등급", "${tempGrade['grade']} (${tempGrade['amp']})", tempGrade['color'] as Color),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 2단: 고전압 안전 및 방수 기밀 상태
        Expanded(
          flex: 33,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF222A35))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.shield_outlined, color: Color(0xFFFFB300), size: 18),
                    SizedBox(width: 6),
                    Text("고전압 안전 및 기밀 진단", style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
                _buildDiagRow("팩 절연 저항 (누전 진단)", "$_insulationResistanceKohm kΩ", _insulationResistanceKohm > 500 ? const Color(0xFF00E676) : const Color(0xFFFF5252)),
                _buildDiagRow("메인 안전 스위치 (DC Switch)", _isDcSwitchClosed ? "정상 체결 (Lock)" : "개방 주의", _isDcSwitchClosed ? const Color(0xFF00E676) : const Color(0xFFFF5252)),
                _buildDiagRow("배터리 팩 방수 커버 밀폐", _isPackCoverClosed ? "정상 밀폐 (OK)" : "점검 필요", _isPackCoverClosed ? const Color(0xFF00E676) : const Color(0xFFFF5252)),
                _buildDiagRow("내부 침수/수분 감지 센서", _isWaterAlarm ? "⚠️ 수분 감지 경고" : "정상 (건조)", _isWaterAlarm ? const Color(0xFFFF5252) : const Color(0xFF00E676)),
                const Divider(color: Colors.white12, height: 12),
                _buildDiagRow("실시간 총 배터리 전압", "${_voltage.toStringAsFixed(1)} V", Colors.white),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 3단: 셀 정밀 전압 및 밸런싱 모니터
        Expanded(
          flex: 34,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF222A35))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.tune, color: Color(0xFF00E676), size: 18),
                        SizedBox(width: 6),
                        Text("셀 밸런싱 정밀 모니터", style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: (cellBal['color'] as Color).withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
                      child: Text("${cellBal['status']}", style: TextStyle(color: cellBal['color'] as Color, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                _buildDiagRow("최고 전압 셀 위치", "#$_cellMaxId번 셀 ($_cellMaxMv mV)", const Color(0xFF00E5FF)),
                _buildDiagRow("최저 전압 셀 위치", "#$_cellMinId번 셀 ($_cellMinMv mV)", const Color(0xFFFF9100)),
                _buildDiagRow("최대 전압 편차 (ΔV)", "$_cellDeltaMv mV", cellBal['color'] as Color),
                const Divider(color: Colors.white12, height: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("셀 전압 분포 밸런스 상태", style: TextStyle(color: Colors.white54, fontSize: 11)),
                        Text("정상 균일", style: TextStyle(color: Color(0xFF00E676), fontSize: 11, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (1.0 - (_cellDeltaMv / 150.0)).clamp(0.0, 1.0),
                        backgroundColor: Colors.white10,
                        valueColor: AlwaysStoppedAnimation<Color>(cellBal['color'] as Color),
                        minHeight: 8,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDiagRow(String title, String value, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: const TextStyle(color: Colors.white60, fontSize: 12)),
        Text(value, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
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
    double liveConsumeWatts = (_voltage * _current).abs();
    if (liveConsumeWatts > 65000) liveConsumeWatts = 0.0;

    return Row(
      children: [
        _buildUnifiedBottomCard("운행시간 · 거리", "${_accumulatedRealTripKm.toStringAsFixed(1)} km", subText: _formatDrivingTime(_drivingSeconds), valueColor: const Color(0xFF00E5FF)),
        _buildUnifiedBottomCard("이번 주행 소모량", "${totalConsumedKwh.toStringAsFixed(1)} kWh", subText: "(-${consumedPct.toStringAsFixed(1)}%)", valueColor: const Color(0xFFFFB300)),
        _buildUnifiedBottomCard("실시간 소모 전력", "${liveConsumeWatts.toStringAsFixed(0)} W", subText: liveConsumeWatts > 1000 ? "소모 높음" : "정상", valueColor: liveConsumeWatts > 1000 ? const Color(0xFFFFB300) : Colors.white),
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

  // =========================================================================
  // [캠핑 모드 대시보드]
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
        Expanded(
          flex: 42,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFFB300).withOpacity(0.4))),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("현재 배터리 잔량", style: TextStyle(color: Colors.white54, fontSize: 13)),
                Text("${_soc.toStringAsFixed(1)} %", style: const TextStyle(color: Color(0xFF00E676), fontSize: 44, fontWeight: FontWeight.bold)),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Column(children: [Text(isCharging ? "실시간 충전 전력" : "실시간 소모 전력", style: const TextStyle(color: Colors.white54, fontSize: 12)), const SizedBox(height: 2), Text(isCharging ? "${_chargePowerKw.toStringAsFixed(1)} kW" : "${liveWatts.toStringAsFixed(0)} W", style: const TextStyle(color: Color(0xFFFFB300), fontSize: 18, fontWeight: FontWeight.bold))]),
                    Column(children: [Text(isCharging ? "시간당 충전율" : "시간당 소모율", style: const TextStyle(color: Colors.white54, fontSize: 12)), const SizedBox(height: 2), Text("${percentPerHour.toStringAsFixed(1)} %/h", style: const TextStyle(color: Colors.cyanAccent, fontSize: 18, fontWeight: FontWeight.bold))]),
                  ],
                ),
                const Divider(color: Colors.white12, height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(color: const Color(0xFF1A212B), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white12)),
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
          flex: 58,
          child: Column(
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF222A35))),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text("🏕️ 배터리 사용 가능 한계 마진 (무시동 공조)", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text("🛡️ 복귀 마진 (20% 도달)", style: TextStyle(color: Colors.white54, fontSize: 11)), const SizedBox(height: 2), Text(margin20Time, style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 20, fontWeight: FontWeight.bold)), Text("가용량: $avail20Kwh kWh", style: const TextStyle(color: Colors.white38, fontSize: 10))]))),
                          const SizedBox(width: 8),
                          Expanded(child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFFF5252).withOpacity(0.3))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text("⚠️ 한계 마진 (0% 방전)", style: TextStyle(color: Colors.white54, fontSize: 11)), const SizedBox(height: 2), Text(margin0Time, style: const TextStyle(color: Color(0xFFFF5252), fontSize: 20, fontWeight: FontWeight.bold)), Text("잔여량: $avail0Kwh kWh", style: const TextStyle(color: Colors.white38, fontSize: 10))]))),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(14), border: Border.all(color: isCharging ? const Color(0xFF00E5FF).withOpacity(0.5) : const Color(0xFF222A35))),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(isCharging ? (isFastCharge ? "⚡ 급속 충전 진행 중" : "🔌 완속 충전 진행 중") : "⚡ 실시간 충전 대기", style: TextStyle(color: isCharging ? const Color(0xFFFFB300) : Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)), Text("${_chargePowerKw.toStringAsFixed(1)} kW", style: TextStyle(color: isCharging ? const Color(0xFFFFB300) : Colors.white54, fontSize: 18, fontWeight: FontWeight.bold))]),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text("80% 목표 도달", style: TextStyle(color: Colors.white54, fontSize: 11)), const SizedBox(height: 2), Text(_calculateTimeToSoc(80.0), style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 18, fontWeight: FontWeight.bold))]))),
                          const SizedBox(width: 8),
                          Expanded(child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFF00E676).withOpacity(0.3))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text("100% 완전 충전", style: TextStyle(color: Colors.white54, fontSize: 11)), const SizedBox(height: 2), Text(_calculateTimeToSoc(100.0), style: const TextStyle(color: Color(0xFF00E676), fontSize: 18, fontWeight: FontWeight.bold))]))),
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
    return Column(mainAxisSize: MainAxisSize.min, children: [Text(title, style: const TextStyle(color: Colors.white54, fontSize: 11)), const SizedBox(height: 2), Text(valueText, style: TextStyle(color: valueColor, fontSize: 13, fontWeight: FontWeight.bold))]);
  }
}

// =========================================================================
// [CustomPainter] 상단 반원 아크 게이지 (굵기 16px, 반경 최대화)
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

    // 배경 반원 트랙 (9시 ➔ 12시 ➔ 3시)
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

    // 12시 정점(0kW) 중앙 분리선
    final centerTickPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3.0;
    canvas.drawLine(
      Offset(center.dx, center.dy - radius - 11),
      Offset(center.dx, center.dy - radius + 11),
      centerTickPaint,
    );

    // 실시간 파워 또는 회생 아크 채우기
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

    // 1. 배터리 온도별 안전 한계 출력 핀 (빨간색)
    final double limitRatio = (safeLimitKw / 50.0).clamp(0.0, 1.0);
    final double limitAngle = -math.pi / 2.0 + (limitRatio * (math.pi / 2.0));
    final limitPinPaint = Paint()
      ..color = const Color(0xFFFF5252)
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    final limitP1 = Offset(center.dx + (radius - 12) * math.cos(limitAngle), center.dy + (radius - 12) * math.sin(limitAngle));
    final limitP2 = Offset(center.dx + (radius + 12) * math.cos(limitAngle), center.dy + (radius + 12) * math.sin(limitAngle));
    canvas.drawLine(limitP1, limitP2, limitPinPaint);

    // 2. 이번 주행 평균 출력 핀 (하늘색)
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
