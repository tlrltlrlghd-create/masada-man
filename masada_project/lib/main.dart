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
  int _currentThemeIndex = 0; // 0: 테마A, 1: 테마B, 2: 테마C, 3: 테마D
  static const int _virtualInitialPage = 1000;
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

  // 실시간 악셀 & 공조 3종 온도 데이터
  int _accelPedalPct = 0;
  double _ptcTemp = 20.0;
  double _evapTemp = 15.0;
  double _envTemp = 25.0;

  // 물리 풋브레이크 & 원페달
  bool _isFootBrakePressed = false;
  int _totalDecelSeconds = 0;
  int _onePedalRegenSeconds = 0;
  int _onePedalScorePct = 100;

  // 에너지 소비 4분할
  double _energyDriveKwh = 0.0;
  double _energyPtcKwh = 0.0;
  double _energyAcKwh = 0.0;
  double _energyStandbyKwh = 0.0;

  // 배터리 평생 실측 이력 데이터
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
  Timer? _drivingTimer;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _virtualInitialPage);
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

  void _showBatteryManagementDialog() {
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
            width: 620,
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.verified_outlined, color: Color(0xFF00E5FF), size: 22),
                        SizedBox(width: 8),
                        Text(
                          "BMS 배터리 정밀 진단 및 평생 이력",
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
                const Divider(color: Colors.white12, height: 16),
                
                const Text("🔋 배터리 평생 누적 이력 (출고 후 영구 보존)", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _buildModalStatCard("총 누적 충전량", "${_totalCumulativeChargeKwh.toStringAsFixed(1)} kWh", const Color(0xFF00E676)),
                    const SizedBox(width: 8),
                    _buildModalStatCard("평생 누적 완충", "$_chargeTimesCount 회", const Color(0xFF00E5FF)),
                    const SizedBox(width: 8),
                    _buildModalStatCard("과방전 차단 이력", "$_dischargeTimesCount 회", _dischargeTimesCount > 0 ? const Color(0xFFFF5252) : const Color(0xFF00E676)),
                  ],
                ),
                const SizedBox(height: 14),

                const Text("🛡️ 고전압 안전 및 셀 밸런싱 세부 상태", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E242C),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    children: [
                      _buildRelayRow("고전압 팩 절연 저항 (누전 진단)", "$_insulationResistanceKohm kΩ", _insulationResistanceKohm > 500 ? const Color(0xFF00E676) : const Color(0xFFFF5252)),
                      const Divider(color: Colors.white10, height: 10),
                      _buildRelayRow("메인 안전 인터록(DC Switch)", _isDcSwitchClosed ? "정상 체결 (Lock)" : "개방 주의", _isDcSwitchClosed ? const Color(0xFF00E676) : const Color(0xFFFF5252)),
                      const Divider(color: Colors.white10, height: 10),
                      _buildRelayRow("배터리 팩 커버 밀폐 상태", _isPackCoverClosed ? "정상 밀폐 (OK)" : "점검 필요", _isPackCoverClosed ? const Color(0xFF00E676) : const Color(0xFFFF5252)),
                      const Divider(color: Colors.white10, height: 10),
                      _buildRelayRow("최고 전압 셀 위치 / 최저 전압 셀 위치", "#$_cellMaxId번 셀 ($_cellMaxMv mV)  /  #$_cellMinId번 셀 ($_cellMinMv mV)", const Color(0xFF00E5FF)),
                    ],
                  ),
                ),
              ],
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
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
        Text(value, style: TextStyle(color: valueColor, fontSize: 13, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildModalStatCard(String title, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E242C),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(color: Colors.white54, fontSize: 11)),
            const SizedBox(height: 3),
            Text(value, style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.bold)),
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
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 4),
              Expanded(
                child: _isCampingMode
                    ? _buildCampingDashboard()
                    : PageView.builder(
                        controller: _pageController,
                        physics: const BouncingScrollPhysics(),
                        onPageChanged: (pageIndex) {
                          setState(() {
                            _currentThemeIndex = pageIndex % 4;
                          });
                        },
                        itemBuilder: (context, index) {
                          int theme = index % 4;
                          if (theme == 0) return _buildThemeAStandardDashboard();
                          if (theme == 1) return _buildThemeBDriverDashboard();
                          if (theme == 2) return _buildThemeCNightDashboard();
                          return _buildThemeDEcoDashboard();
                        },
                      ),
              ),
              if (!_isCampingMode && _currentThemeIndex == 0) ...[
                const SizedBox(height: 4),
                _buildThemeAPowerBar(),
              ],
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
    List<String> themeNames = ["테마 A (가로)", "테마 B (세로)", "테마 C (나이트)", "테마 D (에코)"];

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
                _isCampingMode ? (_chargePowerKw > 0.3 ? "MASADA  CHARGING & CAMPING" : "MASADA  CAMPING") : "MASADA VAN  EV MONITOR",
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: Colors.purpleAccent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.purpleAccent.withOpacity(0.5), width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.swipe, color: Colors.purpleAccent, size: 11),
                    const SizedBox(width: 3),
                    Text(
                      themeNames[_currentThemeIndex],
                      style: const TextStyle(color: Colors.purpleAccent, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
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
              onTap: _showBatteryManagementDialog,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E242C),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.6), width: 1.0),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.tune, color: Color(0xFF00E5FF), size: 14),
                    SizedBox(width: 4),
                    Text(
                      "배터리 관리",
                      style: TextStyle(color: Color(0xFF00E5FF), fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
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
  // [테마 A: 클래식 가로형 레이아웃]
  // =========================================================================
  Widget _buildThemeAStandardDashboard() {
    return Row(
      children: [
        Expanded(flex: 25, child: _buildThemeALeftPanel()),
        const SizedBox(width: 8),
        Expanded(flex: 47, child: _buildThemeACenterSocGauge()),
        const SizedBox(width: 8),
        Expanded(flex: 28, child: _buildThemeARightPanel()),
      ],
    );
  }

  Widget _buildThemeALeftPanel() {
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
                    Text("💰 실시간 유류비 절감", style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold)),
                    Text("카니발 대비", style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text("+${fuelCosts['saved']}", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 36, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 4),
                    const Text("원 절약", style: TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("카니발: ${fuelCosts['carnival']}원", style: const TextStyle(color: Colors.white54, fontSize: 11)),
                    Text("마사다: ${fuelCosts['masada']}원", style: const TextStyle(color: Color(0xFFFFB300), fontSize: 11, fontWeight: FontWeight.bold)),
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
            decoration: BoxDecoration(
              color: const Color(0xFF13171D),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF222A35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("BMS 주행가능거리 (복합 전비)", style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(_bmsDistance.toStringAsFixed(1), style: TextStyle(color: effThemeColor, fontSize: 42, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 6),
                    const Text("km", style: TextStyle(color: Colors.white54, fontSize: 20, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildThemeACenterSocGauge() {
    Color effThemeColor = _getEfficiencyColor(_efficiencyScore);
    double accelRatio = (_accelPedalPct / 100.0).clamp(0.0, 1.0);
    double ptcRatio = ((_ptcTemp - 15.0) / 65.0).clamp(0.0, 1.0);
    double acRatio = ((25.0 - _evapTemp) / 25.0).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF1E242C),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white24, width: 0.8),
              ),
              child: Text(
                "외기온도 ${_envTemp.toStringAsFixed(1)}°C",
                style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
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
                    const Text("ACCEL", style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                    Text("$_accelPedalPct%", style: const TextStyle(color: Color(0xFF00E676), fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Container(
                        width: 12,
                        decoration: BoxDecoration(color: const Color(0xFF222A35), borderRadius: BorderRadius.circular(6)),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                width: 12,
                                height: constraints.maxHeight * accelRatio,
                                decoration: BoxDecoration(color: const Color(0xFF00E676), borderRadius: BorderRadius.circular(6)),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
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
                        width: 210,
                        height: 210,
                        child: CircularProgressIndicator(
                          value: (_soc / 100.0).clamp(0.0, 1.0),
                          strokeWidth: 18,
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
                              Text(_pureDriveTripEfficiency.toStringAsFixed(1), style: TextStyle(color: effThemeColor, fontSize: 24, fontWeight: FontWeight.bold)),
                              const SizedBox(width: 3),
                              Text("km/kWh", style: TextStyle(color: effThemeColor.withOpacity(0.85), fontSize: 14, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(_soc.toStringAsFixed(1), style: TextStyle(color: effThemeColor, fontSize: 50, fontWeight: FontWeight.bold)),
                              Text("%", style: TextStyle(color: effThemeColor, fontSize: 20, fontWeight: FontWeight.bold)),
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
                    const Text("PTC", style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                    Text("${_ptcTemp.toStringAsFixed(0)}°", style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Container(
                        width: 12,
                        decoration: BoxDecoration(color: const Color(0xFF222A35), borderRadius: BorderRadius.circular(6)),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            double halfHeight = constraints.maxHeight / 2.0;
                            return Stack(
                              children: [
                                Positioned(
                                  bottom: halfHeight,
                                  left: 0,
                                  right: 0,
                                  child: Container(height: halfHeight * ptcRatio, decoration: const BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.vertical(top: Radius.circular(6)))),
                                ),
                                Positioned(
                                  top: halfHeight,
                                  left: 0,
                                  right: 0,
                                  child: Container(height: halfHeight * acRatio, decoration: const BoxDecoration(color: Color(0xFF00E5FF), borderRadius: BorderRadius.vertical(bottom: Radius.circular(6)))),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text("${_evapTemp.toStringAsFixed(0)}°", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold)),
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

  Widget _buildThemeARightPanel() {
    Color effThemeColor = _getEfficiencyColor(_efficiencyScore);
    double gainedKm = _accumulatedRegenKwh * _pureDriveTripEfficiency;
    Map<String, int> dist = _calculateEnergyDistribution();
    bool isStopped = _realVehicleSpeedKmh <= 0.5;

    return Column(
      children: [
        Expanded(
          flex: 48,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                    const Text("🌱 1분 효율 점수", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isStopped ? Colors.white10 : effThemeColor.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: isStopped ? Colors.white30 : effThemeColor, width: 0.8),
                      ),
                      child: Text(
                        isStopped ? "⏸️ 신호 대기" : "$_efficiencyScore점",
                        style: TextStyle(color: isStopped ? Colors.white70 : effThemeColor, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("원페달 달성률 $_onePedalScorePct%", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 14, fontWeight: FontWeight.bold)),
                    Text("+${gainedKm.toStringAsFixed(1)}km 회생", style: const TextStyle(color: Color(0xFF00E676), fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (_onePedalScorePct / 100.0).clamp(0.0, 1.0),
                    backgroundColor: Colors.white10,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          flex: 52,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                    Text("⚡ 에너지 소비처 분석", style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                    Text("실시간 누적", style: TextStyle(color: Colors.white38, fontSize: 10)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("구동 ${dist['drive']}%", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold)),
                    Text("히터 ${dist['ptc']}%", style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                    Text("A/C ${dist['ac']}%", style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                    Text("대기 ${dist['stdby']}%", style: const TextStyle(color: Colors.white54, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    height: 8,
                    child: Row(
                      children: [
                        Expanded(flex: dist['drive']!, child: Container(color: const Color(0xFF00E5FF))),
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
        ),
      ],
    );
  }

  Widget _buildThemeAPowerBar() {
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
                      child: const Text("⚠️ 회생제한", style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
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
                  Container(width: barWidth, height: 12, decoration: BoxDecoration(color: const Color(0xFF222A35), borderRadius: BorderRadius.circular(6))),
                  if (_powerKw < -0.1)
                    Positioned(right: halfWidth, child: Container(width: fillWidth, height: 12, decoration: const BoxDecoration(color: Color(0xFF00E5FF), borderRadius: BorderRadius.horizontal(left: Radius.circular(6)))))
                  else if (_powerKw > 0.1)
                    Positioned(left: halfWidth, child: Container(width: fillWidth, height: 12, decoration: BoxDecoration(color: dynamicBarColor, borderRadius: BorderRadius.horizontal(right: Radius.circular(6))))),
                  Positioned(left: halfWidth - 1.0, child: Container(width: 2.0, height: 16, color: Colors.white70)),
                  Positioned(left: pinLeft.clamp(halfWidth, barWidth - 8.0), child: Container(width: 8, height: 18, decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(2.0), boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 3, offset: Offset(0, 1))]))),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // [테마 B: 운전자 집중 세로형 레이아웃]
  // =========================================================================
  Widget _buildThemeBDriverDashboard() {
    return Row(
      children: [
        Expanded(flex: 22, child: _buildVerticalPowerMeter()),
        const SizedBox(width: 8),
        Expanded(flex: 48, child: _buildLargeCenterGaugeHub()),
        const SizedBox(width: 8),
        Expanded(flex: 30, child: _buildRightExpandedPanel()),
      ],
    );
  }

  Widget _buildVerticalPowerMeter() {
    double safeLimitKw = _getSafePowerLimitKw(_batteryTemp);
    Color dynamicPowerColor = _getPowerGaugeColor(_powerKw, _batteryTemp);
    bool isRegen = _powerKw < -0.1;
    bool isPower = _powerKw > 0.1;
    double fillRatio = _powerKw.abs().clamp(0.0, 50.0) / 50.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF222A35))),
      child: Column(
        children: [
          const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.bolt, color: Colors.redAccent, size: 16), SizedBox(width: 2), Text("POWER", style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w900))]),
          const SizedBox(height: 2),
          Text(isPower ? "+${_powerKw.toStringAsFixed(1)} kW" : (isRegen ? "${_powerKw.toStringAsFixed(1)} kW" : "0.0 kW"), style: TextStyle(color: isRegen ? const Color(0xFF00E5FF) : (isPower ? dynamicPowerColor : Colors.white70), fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                double halfHeight = constraints.maxHeight / 2.0;
                double limitTopPin = halfHeight - (halfHeight * (safeLimitKw / 50.0).clamp(0.0, 1.0));
                return Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Container(width: 28, decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white12))),
                    if (isPower) Positioned(bottom: halfHeight, child: Container(width: 28, height: halfHeight * fillRatio, decoration: BoxDecoration(color: dynamicPowerColor, borderRadius: const BorderRadius.vertical(top: Radius.circular(14))))),
                    if (isRegen) Positioned(top: halfHeight, child: Container(width: 28, height: halfHeight * fillRatio, decoration: const BoxDecoration(color: Color(0xFF00E5FF), borderRadius: BorderRadius.vertical(bottom: Radius.circular(14))))),
                    Positioned(top: halfHeight - 1, child: Container(width: 38, height: 2, color: Colors.white)),
                    Positioned(top: limitTopPin - 2, left: -2, child: Container(width: 32, height: 4, decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(2)))),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.recycling, color: Color(0xFF00E5FF), size: 16), SizedBox(width: 2), Text("REGEN", style: TextStyle(color: Color(0xFF00E5FF), fontSize: 13, fontWeight: FontWeight.w900))]),
        ],
      ),
    );
  }

  Widget _buildLargeCenterGaugeHub() {
    Color effThemeColor = _getEfficiencyColor(_efficiencyScore);
    double accelRatio = (_accelPedalPct / 100.0).clamp(0.0, 1.0);
    double ptcRatio = ((_ptcTemp - 15.0) / 65.0).clamp(0.0, 1.0);
    double acRatio = ((25.0 - _evapTemp) / 25.0).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF222A35))),
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white24, width: 0.8)),
              child: Text("외기 ${_envTemp.toStringAsFixed(1)}°C", style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
          Row(
            children: [
              Expanded(
                flex: 14,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("ACCEL", style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                    Text("$_accelPedalPct%", style: const TextStyle(color: Color(0xFF00E676), fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Container(
                        width: 14,
                        decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(7)),
                        child: LayoutBuilder(builder: (c, constraints) => Align(alignment: Alignment.bottomCenter, child: Container(width: 14, height: constraints.maxHeight * accelRatio, decoration: BoxDecoration(color: const Color(0xFF00E676), borderRadius: BorderRadius.circular(7))))),
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text("0%", style: TextStyle(color: Colors.white30, fontSize: 9)),
                  ],
                ),
              ),
              Expanded(
                flex: 72,
                child: Center(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(width: 230, height: 230, child: CircularProgressIndicator(value: (_soc / 100.0).clamp(0.0, 1.0), strokeWidth: 22, backgroundColor: const Color(0xFF1E242C), valueColor: AlwaysStoppedAnimation<Color>(effThemeColor))),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [Text(_bmsDistance.toStringAsFixed(0), style: const TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.w900)), const SizedBox(width: 3), const Text("km", style: TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.bold))]),
                          Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [Text(_soc.toStringAsFixed(1), style: TextStyle(color: effThemeColor, fontSize: 52, fontWeight: FontWeight.w900)), Text("%", style: TextStyle(color: effThemeColor, fontSize: 24, fontWeight: FontWeight.bold))]),
                          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: effThemeColor.withOpacity(0.15), borderRadius: BorderRadius.circular(6)), child: Text("${_pureDriveTripEfficiency.toStringAsFixed(1)} km/kWh", style: TextStyle(color: effThemeColor, fontSize: 14, fontWeight: FontWeight.bold))),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 14,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("PTC", style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                    Text("${_ptcTemp.toStringAsFixed(0)}°", style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Container(
                        width: 14,
                        decoration: BoxDecoration(color: const Color(0xFF1E242C), borderRadius: BorderRadius.circular(7)),
                        child: LayoutBuilder(
                          builder: (c, constraints) {
                            double half = constraints.maxHeight / 2.0;
                            return Stack(children: [
                              Align(alignment: Alignment.center, child: Container(width: 14, height: 2, color: Colors.white54)),
                              Positioned(bottom: half, left: 0, right: 0, child: Container(height: half * ptcRatio, decoration: const BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.vertical(top: Radius.circular(7))))),
                              Positioned(top: half, left: 0, right: 0, child: Container(height: half * acRatio, decoration: const BoxDecoration(color: Color(0xFF00E5FF), borderRadius: BorderRadius.vertical(bottom: Radius.circular(7))))),
                            ]);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text("${_evapTemp.toStringAsFixed(0)}°", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 12, fontWeight: FontWeight.bold)),
                    const Text("A/C", style: TextStyle(color: Color(0xFF00E5FF), fontSize: 10, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRightExpandedPanel() {
    Map<String, int> fuelCosts = _calculateDetailedFuelCosts();
    Map<String, int> dist = _calculateEnergyDistribution();
    Color effThemeColor = _getEfficiencyColor(_efficiencyScore);
    bool isStopped = _realVehicleSpeedKmh <= 0.5;

    return Column(
      children: [
        Expanded(
          flex: 50,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF222A35))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text("💰 실시간 유류비 절감", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)), Text("카니발 대비", style: TextStyle(color: Colors.white38, fontSize: 11))]),
                const SizedBox(height: 2),
                Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [Text("+${fuelCosts['saved']}", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 36, fontWeight: FontWeight.w900)), const SizedBox(width: 4), const Text("원", style: TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.bold))]),
                const SizedBox(height: 4),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text("카니발: ${fuelCosts['carnival']}원", style: const TextStyle(color: Colors.white54, fontSize: 11)), Text("마사다: ${fuelCosts['masada']}원", style: const TextStyle(color: Color(0xFFFFB300), fontSize: 11, fontWeight: FontWeight.bold))]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          flex: 50,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF222A35))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text("🌱 원페달 $_onePedalScorePct%", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 13, fontWeight: FontWeight.bold)), Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: isStopped ? Colors.white10 : effThemeColor.withOpacity(0.2), borderRadius: BorderRadius.circular(5)), child: Text(isStopped ? "⏸️ 대기" : "$_efficiencyScore점", style: TextStyle(color: isStopped ? Colors.white70 : effThemeColor, fontSize: 11, fontWeight: FontWeight.bold)))]),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text("구동 ${dist['drive']}%", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold)), Text("히터 ${dist['ptc']}%", style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)), Text("A/C ${dist['ac']}%", style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold)), Text("대기 ${dist['stdby']}%", style: const TextStyle(color: Colors.white54, fontSize: 11))]),
                const SizedBox(height: 4),
                ClipRRect(borderRadius: BorderRadius.circular(4), child: SizedBox(height: 8, child: Row(children: [Expanded(flex: dist['drive']!, child: Container(color: const Color(0xFF00E5FF))), Expanded(flex: dist['ptc']!, child: Container(color: Colors.redAccent)), Expanded(flex: dist['ac']!, child: Container(color: Colors.cyanAccent)), Expanded(flex: dist['stdby']!, child: Container(color: Colors.white38))]))),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // =========================================================================
  // [테마 C: 나이트 드라이브 다크 모드]
  // =========================================================================
  Widget _buildThemeCNightDashboard() {
    return Container(
      decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.amber.withOpacity(0.3), width: 1.2)),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            flex: 35,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("NIGHT DRIVE MODE", style: TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 2.0)),
                const SizedBox(height: 10),
                Text("${_soc.toStringAsFixed(1)}%", style: const TextStyle(color: Colors.amber, fontSize: 72, fontWeight: FontWeight.w900)),
                const SizedBox(height: 10),
                Text("BMS 주행거리: ${_bmsDistance.toStringAsFixed(0)} km", style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const VerticalDivider(color: Colors.white24, width: 32),
          Expanded(
            flex: 65,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildNightMetric("실시간 파워", "${_powerKw.toStringAsFixed(1)} kW", Colors.amberAccent),
                    _buildNightMetric("배터리 온도", "${_batteryTemp.toStringAsFixed(1)}°C", Colors.orange),
                    _buildNightMetric("원페달 점수", "$_onePedalScorePct점", Colors.greenAccent),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.amber.withOpacity(0.2))),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Text("외기: ${_envTemp.toStringAsFixed(1)}°C", style: const TextStyle(color: Colors.white70, fontSize: 15)),
                      Text("히터PTC: ${_ptcTemp.toStringAsFixed(0)}°C", style: const TextStyle(color: Colors.redAccent, fontSize: 15)),
                      Text("에어컨: ${_evapTemp.toStringAsFixed(0)}°C", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 15)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNightMetric(String title, String value, Color color) {
    return Column(
      children: [
        Text(title, style: const TextStyle(color: Colors.white54, fontSize: 13)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.bold)),
      ],
    );
  }

  // =========================================================================
  // [테마 D: 에코 챌린지 마스터 모드]
  // =========================================================================
  Widget _buildThemeDEcoDashboard() {
    double gainedKm = _accumulatedRegenKwh * _pureDriveTripEfficiency;
    Map<String, int> dist = _calculateEnergyDistribution();

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF0A1F13), Color(0xFF0D1117)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF00E676).withOpacity(0.5), width: 1.5),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            flex: 40,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.eco, color: Color(0xFF00E676), size: 22), SizedBox(width: 6), Text("ECO CHALLENGE", style: TextStyle(color: Color(0xFF00E676), fontSize: 15, fontWeight: FontWeight.bold))]),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(_pureDriveTripEfficiency.toStringAsFixed(1), style: const TextStyle(color: Color(0xFF00E676), fontSize: 62, fontWeight: FontWeight.w900)),
                    const SizedBox(width: 4),
                    const Text("km/kWh", style: TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 6),
                Text("회생 제동으로 +${gainedKm.toStringAsFixed(1)}km 추가 확보!", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 13, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const VerticalDivider(color: Colors.white24, width: 32),
          Expanded(
            flex: 60,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("원페달 드라이빙 마스터리", style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold)),
                    Text("$_onePedalScorePct%", style: const TextStyle(color: Color(0xFF00E676), fontSize: 20, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: (_onePedalScorePct / 100.0).clamp(0.0, 1.0),
                    backgroundColor: Colors.white10,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E676)),
                    minHeight: 12,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildEcoCard("모터 구동", "${dist['drive']}%", const Color(0xFF00E5FF)),
                    _buildEcoCard("공조(냉/난방)", "${dist['ptc']! + dist['ac']!}%", Colors.orangeAccent),
                    _buildEcoCard("배터리 잔량", "${_soc.toStringAsFixed(0)}%", const Color(0xFF00E676)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEcoCard(String title, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: const Color(0xFF16221B), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.4))),
      child: Column(
        children: [
          Text(title, style: const TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 3),
          Text(value, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // =========================================================================
  // [캠핑 모드 & 공통 하단 위젯]
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

  Widget _buildBottomStatusBar() {
    Map<String, dynamic> tempGrade = _getBatteryTempGrade();
    double totalConsumedKwh = _energyDriveKwh + _energyPtcKwh + _energyAcKwh + _energyStandbyKwh;
    double consumedPct = (_batteryTotalKwh > 0) ? (totalConsumedKwh / _batteryTotalKwh) * 100.0 : 0.0;
    double liveConsumeWatts = (_voltage * _current).abs();
    if (liveConsumeWatts > 65000) liveConsumeWatts = 0.0;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildBottomCard(title: "운행시간 · 이번주행", child: Column(mainAxisSize: MainAxisSize.min, children: [Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [Text(_accumulatedRealTripKm.toStringAsFixed(1), style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 16, fontWeight: FontWeight.bold)), const SizedBox(width: 2), const Text("km", style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold))]), const SizedBox(height: 1), Text(_formatDrivingTime(_drivingSeconds), style: const TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w500))])),
        _buildBottomCard(title: "이번 운행 소모량", child: Row(mainAxisSize: MainAxisSize.min, children: [Text("${totalConsumedKwh.toStringAsFixed(1)} kWh", style: const TextStyle(color: Color(0xFFFFB300), fontSize: 16, fontWeight: FontWeight.bold)), const SizedBox(width: 4), Text("(-${consumedPct.toStringAsFixed(1)}%)", style: const TextStyle(color: Color(0xFFFF5252), fontSize: 13, fontWeight: FontWeight.bold))])),
        _buildBottomCard(title: "실시간 소모 전력", child: Text("${liveConsumeWatts.toStringAsFixed(0)} W", style: TextStyle(color: liveConsumeWatts > 1000 ? const Color(0xFFFFB300) : Colors.white, fontSize: 16, fontWeight: FontWeight.bold))),
        _buildBottomCard(title: "배터리 건강(SOH)", child: Text("$_soh %", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 16, fontWeight: FontWeight.bold))),
        _buildBottomCard(
          title: "배터리온도 & 급속허용",
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [Text("${_batteryTemp.toStringAsFixed(1)}°C", style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)), const SizedBox(width: 6), Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), decoration: BoxDecoration(color: (tempGrade['color'] as Color).withOpacity(0.2), borderRadius: BorderRadius.circular(4), border: Border.all(color: tempGrade['color'] as Color, width: 0.8)), child: Text("${tempGrade['grade']} (${tempGrade['amp']})", style: TextStyle(color: tempGrade['color'] as Color, fontSize: 11, fontWeight: FontWeight.bold)))]),
              const SizedBox(height: 3),
              Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(width: 90, height: 5, decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), gradient: const LinearGradient(colors: [Color(0xFF2979FF), Color(0xFF00E5FF), Color(0xFF00E676), Color(0xFFFFD600), Color(0xFFFF9100), Color(0xFFFF5252)]))),
                  Positioned(left: (((_batteryTemp + 10) / 70.0).clamp(0.0, 1.0) * 82), child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black, blurRadius: 2)]))),
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
                Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), decoration: BoxDecoration(color: (loadGrade['color'] as Color).withOpacity(0.2), borderRadius: BorderRadius.circular(4), border: Border.all(color: loadGrade['color'] as Color, width: 0.8)), child: Text("${loadGrade['text']}", style: TextStyle(color: loadGrade['color'] as Color, fontSize: 11, fontWeight: FontWeight.bold))),
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
                Text("${_chargePowerKw.toStringAsFixed(1)} kW", style: TextStyle(color: isChargingOrRegen ? const Color(0xFFFFB300) : Colors.white70, fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1), decoration: BoxDecoration(color: const Color(0xFF00E5FF).withOpacity(0.15), borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4))), child: Text("80% ${_calculateTimeToSoc(80.0)}", style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold))),
                const SizedBox(width: 4),
                Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1), decoration: BoxDecoration(color: const Color(0xFF00E676).withOpacity(0.15), borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFF00E676).withOpacity(0.4))), child: Text("100% ${_calculateTimeToSoc(100.0)}", style: const TextStyle(color: Color(0xFF00E676), fontSize: 11, fontWeight: FontWeight.bold))),
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
                Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), decoration: BoxDecoration(color: (cellBal['color'] as Color).withOpacity(0.2), borderRadius: BorderRadius.circular(4), border: Border.all(color: cellBal['color'] as Color, width: 0.8)), child: Text("${cellBal['status']}", style: TextStyle(color: cellBal['color'] as Color, fontSize: 11, fontWeight: FontWeight.bold))),
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
        decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(9), border: Border.all(color: const Color(0xFF222A35))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [Text(title, style: const TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w500)), const SizedBox(height: 2), child]),
      ),
    );
  }

  Widget _buildExtendedCard({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: const Color(0xFF13171D), borderRadius: BorderRadius.circular(9), border: Border.all(color: const Color(0xFF222A35))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [Text(title, style: const TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w500)), const SizedBox(height: 2), child]),
    );
  }
}
