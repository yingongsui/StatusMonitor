import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppState extends ChangeNotifier {
  static const int maxDataPoints = 25;

  // --- Configuration ---
  ThemeMode _themeMode = ThemeMode.dark;
  ThemeMode get themeMode => _themeMode;

  bool _isCpuEnabled = true;
  bool _isMemEnabled = true;
  bool _isNetEnabled = true;

  bool get isCpuEnabled => _isCpuEnabled;
  bool get isMemEnabled => _isMemEnabled;
  bool get isNetEnabled => _isNetEnabled;

  double _cpuInterval = 1500;
  double _memInterval = 1500;
  double _netInterval = 1000;

  double get cpuInterval => _cpuInterval;
  double get memInterval => _memInterval;
  double get resourceInterval => _cpuInterval;
  double get netInterval => _netInterval;

  // --- Status Bar Notification Settings ---
  bool _isStatusBarEnabled = true;
  String _statusBarMode = "both"; // "usage", "speed", "both"
  String _statusBarCpuMetric = "time"; // "time" (Time-Occupied) or "freq" (Frequency-Weighted)

  bool get isStatusBarEnabled => _isStatusBarEnabled;
  String get statusBarMode => _statusBarMode;
  String get statusBarCpuMetric => _statusBarCpuMetric;

  // --- Floating Window Settings ---
  bool _isFloatingEnabled = false;
  String _floatingMode = "usage"; // "usage", "speed", "both"
  double _floatingScale = 0.10; // 0.05, 0.075, 0.10, 0.125, 0.15 (5% - 15% of screen width)
  double _floatingOpacity = 0.80; // 0.3 - 1.0 (7 steps: 30% - 100%)
  bool _isFloatingTapEnabled = false;

  bool get isFloatingEnabled => _isFloatingEnabled;
  String get floatingMode => _floatingMode;
  double get floatingScale => _floatingScale;
  double get floatingOpacity => _floatingOpacity;
  bool get isFloatingTapEnabled => _isFloatingTapEnabled;

  // --- Total Memory Capacity (GB) ---
  double _totalMemGb = 8.0;
  double get totalMemGb => _totalMemGb;
  double get usedMemGb => (_totalMemGb * (currentMemUsage / 100.0)).clamp(0.0, _totalMemGb);
  double get freeMemGb => (_totalMemGb - usedMemGb).clamp(0.0, _totalMemGb);

  void setTotalMemory(double totalGb) {
    if (totalGb > 0 && totalGb != _totalMemGb) {
      _totalMemGb = totalGb;
      notifyListeners();
    }
  }

  // --- Persistence Keys ---
  static const String _keyThemeMode = "settings_theme_mode";
  static const String _keyCpuEnabled = "settings_cpu_enabled";
  static const String _keyMemEnabled = "settings_mem_enabled";
  static const String _keyNetEnabled = "settings_net_enabled";
  static const String _keyCpuInterval = "settings_cpu_interval";
  static const String _keyMemInterval = "settings_mem_interval";
  static const String _keyNetInterval = "settings_net_interval";
  static const String _keyStatusBarEnabled = "settings_statusbar_enabled";
  static const String _keyStatusBarMode = "settings_statusbar_mode";
  static const String _keyStatusBarCpuMetric = "settings_statusbar_cpu_metric";
  static const String _keyFloatingEnabled = "settings_floating_enabled";
  static const String _keyFloatingMode = "settings_floating_mode";
  static const String _keyFloatingScale = "settings_floating_scale";
  static const String _keyFloatingOpacity = "settings_floating_opacity";
  static const String _keyFloatingTapEnabled = "settings_floating_tap_enabled";

  AppState();

  Future<void> loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isDark = prefs.getBool(_keyThemeMode) ?? true;
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;

      _isCpuEnabled = prefs.getBool(_keyCpuEnabled) ?? true;
      _isMemEnabled = prefs.getBool(_keyMemEnabled) ?? true;
      _isNetEnabled = prefs.getBool(_keyNetEnabled) ?? true;

      _cpuInterval = prefs.getDouble(_keyCpuInterval) ?? 1500;
      _memInterval = prefs.getDouble(_keyMemInterval) ?? 1500;
      _netInterval = prefs.getDouble(_keyNetInterval) ?? 1000;

      _isStatusBarEnabled = prefs.getBool(_keyStatusBarEnabled) ?? true;
      _statusBarMode = prefs.getString(_keyStatusBarMode) ?? "usage";
      _statusBarCpuMetric = prefs.getString(_keyStatusBarCpuMetric) ?? "time";

      _isFloatingEnabled = prefs.getBool(_keyFloatingEnabled) ?? false;
      _floatingMode = prefs.getString(_keyFloatingMode) ?? "usage";
      _floatingScale = prefs.getDouble(_keyFloatingScale) ?? 0.10;
      _floatingOpacity = prefs.getDouble(_keyFloatingOpacity) ?? 0.80;
      _isFloatingTapEnabled = prefs.getBool(_keyFloatingTapEnabled) ?? false;

      notifyListeners();
    } catch (_) {}
  }

  // --- CPU Calculation Mode 1: Time-Occupied (Jiffies) ---
  List<FlSpot> cpuTimeSpots = List.generate(
    maxDataPoints,
    (i) => FlSpot(i.toDouble(), 0),
  );

  // --- CPU Calculation Mode 2: Frequency-Weighted Average ---
  List<FlSpot> cpuFreqSpots = List.generate(
    maxDataPoints,
    (i) => FlSpot(i.toDouble(), 0),
  );

  List<FlSpot> get cpuSpots => cpuTimeSpots;

  // --- Memory Telemetry ---
  List<FlSpot> memSpots = List.generate(
    maxDataPoints,
    (i) => FlSpot(i.toDouble(), 0),
  );

  // --- Network Telemetry ---
  List<FlSpot> netDownSpots = List.generate(
    maxDataPoints,
    (i) => FlSpot(i.toDouble(), 0),
  );

  List<FlSpot> netUpSpots = List.generate(
    maxDataPoints,
    (i) => FlSpot(i.toDouble(), 0),
  );

  double currentDownSpeedBytes = 0.0;
  double currentUpSpeedBytes = 0.0;
  double _smoothedDownBytes = 0.0;
  double _smoothedUpBytes = 0.0;

  // --- Statistics for Time-Occupied CPU Usage ---
  double get currentCpuTimeUsage => cpuTimeSpots.isNotEmpty ? cpuTimeSpots.last.y : 0.0;
  double get currentCpuUsage => currentCpuTimeUsage;

  double get minCpuTimeUsage {
    if (cpuTimeSpots.isEmpty) return 0.0;
    return cpuTimeSpots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
  }

  double get maxCpuTimeUsage {
    if (cpuTimeSpots.isEmpty) return 0.0;
    return cpuTimeSpots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
  }

  double get avgCpuTimeUsage {
    if (cpuTimeSpots.isEmpty) return 0.0;
    final sum = cpuTimeSpots.map((s) => s.y).reduce((a, b) => a + b);
    return sum / cpuTimeSpots.length;
  }

  // --- Statistics for Frequency-Weighted CPU Usage ---
  double get currentCpuFreqUsage => cpuFreqSpots.isNotEmpty ? cpuFreqSpots.last.y : 0.0;

  double get minCpuFreqUsage {
    if (cpuFreqSpots.isEmpty) return 0.0;
    return cpuFreqSpots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
  }

  double get maxCpuFreqUsage {
    if (cpuFreqSpots.isEmpty) return 0.0;
    return cpuFreqSpots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
  }

  double get avgCpuFreqUsage {
    if (cpuFreqSpots.isEmpty) return 0.0;
    final sum = cpuFreqSpots.map((s) => s.y).reduce((a, b) => a + b);
    return sum / cpuFreqSpots.length;
  }

  // --- Statistics for Memory Usage ---
  double get currentMemUsage => memSpots.isNotEmpty ? memSpots.last.y : 0.0;

  double get minMemUsage {
    if (memSpots.isEmpty) return 0.0;
    return memSpots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
  }

  double get maxMemUsage {
    if (memSpots.isEmpty) return 0.0;
    return memSpots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
  }

  double get avgMemUsage {
    if (memSpots.isEmpty) return 0.0;
    final sum = memSpots.map((s) => s.y).reduce((a, b) => a + b);
    return sum / memSpots.length;
  }

  // --- Statistics for Network Speed ---
  double get currentDownSpeedKb => currentDownSpeedBytes / 1024.0;
  double get currentUpSpeedKb => currentUpSpeedBytes / 1024.0;
  double get currentTotalSpeedBytes => currentDownSpeedBytes + currentUpSpeedBytes;
  double get currentTotalSpeedKb => currentTotalSpeedBytes / 1024.0;

  String get currentDownSpeedFormatted => formatSpeed(currentDownSpeedBytes);
  String get currentUpSpeedFormatted => formatSpeed(currentUpSpeedBytes);
  String get currentTotalSpeedFormatted => formatFixedSpeed(currentTotalSpeedBytes);

  double get minDownSpeedKb {
    if (netDownSpots.isEmpty) return 0.0;
    return netDownSpots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
  }

  double get maxDownSpeedKb {
    if (netDownSpots.isEmpty) return 0.0;
    return netDownSpots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
  }

  double get avgDownSpeedKb {
    if (netDownSpots.isEmpty) return 0.0;
    final sum = netDownSpots.map((s) => s.y).reduce((a, b) => a + b);
    return sum / netDownSpots.length;
  }

  double get minUpSpeedKb {
    if (netUpSpots.isEmpty) return 0.0;
    return netUpSpots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
  }

  double get maxUpSpeedKb {
    if (netUpSpots.isEmpty) return 0.0;
    return netUpSpots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
  }

  double get avgUpSpeedKb {
    if (netUpSpots.isEmpty) return 0.0;
    final sum = netUpSpots.map((s) => s.y).reduce((a, b) => a + b);
    return sum / netUpSpots.length;
  }

  // Robust speed formatter preventing erratic fractional digit flickering
  static String formatSpeed(double bytesPerSec) {
    if (bytesPerSec <= 0) return "0 B/s";
    if (bytesPerSec >= 1024 * 1024 * 1024) {
      return "${(bytesPerSec / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB/s";
    }
    if (bytesPerSec >= 1024 * 1024) {
      return "${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s";
    }
    if (bytesPerSec >= 10 * 1024) {
      return "${(bytesPerSec / 1024).toInt()} KB/s";
    }
    if (bytesPerSec >= 1024) {
      return "${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s";
    }
    return "${bytesPerSec.toInt()} B/s";
  }

  // Fixed-width speed formatter ensuring strictly constant string length (10 characters)
  static String formatFixedSpeed(double bytesPerSec) {
    if (bytesPerSec <= 0) {
      return "  0.0 KB/s";
    }
    final kb = bytesPerSec / 1024.0;
    if (kb >= 999.95 * 1024.0) {
      final gb = kb / (1024.0 * 1024.0);
      return "${gb.toStringAsFixed(1).padLeft(5)} GB/s";
    }
    if (kb >= 999.95) {
      final mb = kb / 1024.0;
      return "${mb.toStringAsFixed(1).padLeft(5)} MB/s";
    }
    return "${kb.toStringAsFixed(1).padLeft(5)} KB/s";
  }

  // --- Settings Mutators with Auto-Persistence ---

  void toggleTheme(bool isDark) {
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setBool(_keyThemeMode, isDark));
  }

  void updateResourceInterval(double interval) {
    _cpuInterval = interval;
    _memInterval = interval;
    notifyListeners();
    SharedPreferences.getInstance().then((p) {
      p.setDouble(_keyCpuInterval, interval);
      p.setDouble(_keyMemInterval, interval);
    });
  }

  void updateCpuSettings(bool enabled, [double? interval]) {
    _isCpuEnabled = enabled;
    if (interval != null) {
      _cpuInterval = interval;
      _memInterval = interval;
    }
    notifyListeners();
    SharedPreferences.getInstance().then((p) {
      p.setBool(_keyCpuEnabled, enabled);
      if (interval != null) {
        p.setDouble(_keyCpuInterval, interval);
        p.setDouble(_keyMemInterval, interval);
      }
    });
  }

  void updateMemSettings(bool enabled, [double? interval]) {
    _isMemEnabled = enabled;
    if (interval != null) {
      _cpuInterval = interval;
      _memInterval = interval;
    }
    notifyListeners();
    SharedPreferences.getInstance().then((p) {
      p.setBool(_keyMemEnabled, enabled);
      if (interval != null) {
        p.setDouble(_keyCpuInterval, interval);
        p.setDouble(_keyMemInterval, interval);
      }
    });
  }

  void updateNetSettings(bool enabled, double interval) {
    _isNetEnabled = enabled;
    _netInterval = interval;
    notifyListeners();
    SharedPreferences.getInstance().then((p) {
      p.setBool(_keyNetEnabled, enabled);
      p.setDouble(_keyNetInterval, interval);
    });
  }

  void updateStatusBarSettings(bool enabled, String mode, [String? cpuMetric]) {
    _isStatusBarEnabled = enabled;
    _statusBarMode = mode;
    if (cpuMetric != null) {
      _statusBarCpuMetric = cpuMetric;
    }
    notifyListeners();
    SharedPreferences.getInstance().then((p) {
      p.setBool(_keyStatusBarEnabled, enabled);
      p.setString(_keyStatusBarMode, mode);
      if (cpuMetric != null) {
        p.setString(_keyStatusBarCpuMetric, cpuMetric);
      }
    });
  }

  void updateFloatingSettings({
    bool? enabled,
    String? mode,
    double? scale,
    double? opacity,
    bool? tapEnabled,
  }) {
    if (enabled != null) _isFloatingEnabled = enabled;
    if (mode != null) _floatingMode = mode;
    if (scale != null) _floatingScale = scale;
    if (opacity != null) _floatingOpacity = opacity;
    if (tapEnabled != null) _isFloatingTapEnabled = tapEnabled;
    notifyListeners();

    SharedPreferences.getInstance().then((prefs) {
      if (enabled != null) prefs.setBool(_keyFloatingEnabled, enabled);
      if (mode != null) prefs.setString(_keyFloatingMode, mode);
      if (scale != null) prefs.setDouble(_keyFloatingScale, scale);
      if (opacity != null) prefs.setDouble(_keyFloatingOpacity, opacity);
      if (tapEnabled != null) prefs.setBool(_keyFloatingTapEnabled, tapEnabled);
    });
  }

  // --- Shift Windows for CPU ---
  void addCpuData(double timeUsage, [double? freqUsage]) {
    final clampedTime = timeUsage.clamp(0.0, 100.0);
    final clampedFreq = (freqUsage ?? timeUsage).clamp(0.0, 100.0);

    final updatedTime = List<FlSpot>.generate(maxDataPoints, (i) {
      if (i < maxDataPoints - 1) {
        return FlSpot(i.toDouble(), cpuTimeSpots[i + 1].y);
      } else {
        return FlSpot(i.toDouble(), clampedTime);
      }
    });

    final updatedFreq = List<FlSpot>.generate(maxDataPoints, (i) {
      if (i < maxDataPoints - 1) {
        return FlSpot(i.toDouble(), cpuFreqSpots[i + 1].y);
      } else {
        return FlSpot(i.toDouble(), clampedFreq);
      }
    });

    cpuTimeSpots = updatedTime;
    cpuFreqSpots = updatedFreq;
    notifyListeners();
  }

  // --- Shift Window for Memory ---
  void addMemData(double newValue) {
    final clamped = newValue.clamp(0.0, 100.0);
    final updated = List<FlSpot>.generate(maxDataPoints, (i) {
      if (i < maxDataPoints - 1) {
        return FlSpot(i.toDouble(), memSpots[i + 1].y);
      } else {
        return FlSpot(i.toDouble(), clamped);
      }
    });
    memSpots = updated;
    notifyListeners();
  }

  // --- Shift Window for Network (with Low-Pass EMA filter) ---
  void addNetData(double downBytes, double upBytes) {
    const alpha = 0.45;
    _smoothedDownBytes = _smoothedDownBytes == 0.0
        ? downBytes
        : (alpha * downBytes) + ((1.0 - alpha) * _smoothedDownBytes);
    _smoothedUpBytes = _smoothedUpBytes == 0.0
        ? upBytes
        : (alpha * upBytes) + ((1.0 - alpha) * _smoothedUpBytes);

    currentDownSpeedBytes = _smoothedDownBytes;
    currentUpSpeedBytes = _smoothedUpBytes;

    final downKb = (_smoothedDownBytes / 1024.0).clamp(0.0, 1000000.0);
    final upKb = (_smoothedUpBytes / 1024.0).clamp(0.0, 1000000.0);

    final updatedDown = List<FlSpot>.generate(maxDataPoints, (i) {
      if (i < maxDataPoints - 1) {
        return FlSpot(i.toDouble(), netDownSpots[i + 1].y);
      } else {
        return FlSpot(i.toDouble(), downKb);
      }
    });

    final updatedUp = List<FlSpot>.generate(maxDataPoints, (i) {
      if (i < maxDataPoints - 1) {
        return FlSpot(i.toDouble(), netUpSpots[i + 1].y);
      } else {
        return FlSpot(i.toDouble(), upKb);
      }
    });

    netDownSpots = updatedDown;
    netUpSpots = updatedUp;
    notifyListeners();
  }
}
