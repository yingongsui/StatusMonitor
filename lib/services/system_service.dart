import 'package:flutter/services.dart';
import '../app_state.dart';

class SystemService {
  static const _channel = MethodChannel('com.example.statusbarshow/sysinfo');

  // Returns [totalMb, availMb]
  static Future<List<int>> getMemoryInfo() async {
    try {
      final dynamic res = await _channel.invokeMethod('getMemInfo');
      return (res as List<dynamic>).map((e) => (e as int)).toList();
    } catch (_) {
      return [0, 0];
    }
  }

  // Returns real-time CPU calculation metrics: { 'timeBased': double, 'freqWeighted': double }
  static Future<Map<String, double>?> getCpuUsage() async {
    try {
      final dynamic res = await _channel.invokeMethod('getCpuUsage');
      if (res is Map) {
        return {
          'timeBased': (res['timeBased'] as num?)?.toDouble() ?? -1.0,
          'freqWeighted': (res['freqWeighted'] as num?)?.toDouble() ?? -1.0,
        };
      }
    } catch (_) {}
    return null;
  }

  // Returns real-time network speed in bytes/sec: { 'downSpeed': double, 'upSpeed': double }
  static Future<Map<String, double>?> getNetworkSpeed() async {
    try {
      final dynamic res = await _channel.invokeMethod('getNetworkSpeed');
      if (res is Map) {
        return {
          'downSpeed': (res['downSpeed'] as num?)?.toDouble() ?? 0.0,
          'upSpeed': (res['upSpeed'] as num?)?.toDouble() ?? 0.0,
        };
      }
    } catch (_) {}
    return null;
  }

  // Convenient one-line sync directly from AppState
  static Future<bool> syncFromAppState(AppState state) {
    return updateStatusBar(
      enabled: state.isStatusBarEnabled,
      mode: state.statusBarMode,
      cpuMetric: state.statusBarCpuMetric,
      intervalMs: state.cpuInterval.toInt(),
      cpuEnabled: state.isCpuEnabled,
      memEnabled: state.isMemEnabled,
      netEnabled: state.isNetEnabled,
      floatingEnabled: state.isFloatingEnabled,
      floatingMode: state.floatingMode,
      floatingScale: state.floatingScale,
      floatingOpacity: state.floatingOpacity,
      floatingTapEnabled: state.isFloatingTapEnabled,
    );
  }

  // Updates native Android persistent background foreground service, status bar icon, and floating overlay
  static Future<bool> updateStatusBar({
    required bool enabled,
    required String mode, // "usage", "speed", "both"
    String cpuMetric = "time",
    int intervalMs = 1000,
    bool cpuEnabled = true,
    bool memEnabled = true,
    bool netEnabled = true,
    bool floatingEnabled = false,
    String floatingMode = "usage",
    double floatingScale = 0.10,
    double floatingOpacity = 0.80,
    bool floatingTapEnabled = false,
  }) async {
    try {
      final dynamic res = await _channel.invokeMethod('updateStatusBar', {
        'enabled': enabled,
        'mode': mode,
        'cpuMetric': cpuMetric,
        'intervalMs': intervalMs,
        'cpuEnabled': cpuEnabled,
        'memEnabled': memEnabled,
        'netEnabled': netEnabled,
        'floatingEnabled': floatingEnabled,
        'floatingMode': floatingMode,
        'floatingScale': floatingScale,
        'floatingOpacity': floatingOpacity,
        'floatingTapEnabled': floatingTapEnabled,
      });
      return res == true;
    } catch (_) {
      return false;
    }
  }

  // Check if system overlay permission (SYSTEM_ALERT_WINDOW) is granted
  static Future<bool> checkOverlayPermission() async {
    try {
      final bool? res = await _channel.invokeMethod('checkOverlayPermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  // Open System Settings screen to grant overlay permission
  static Future<bool> requestOverlayPermission() async {
    try {
      final bool? res = await _channel.invokeMethod('requestOverlayPermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  // Open external web URL in default browser
  static Future<bool> openUrl(String url) async {
    try {
      final bool? res = await _channel.invokeMethod('openUrl', {'url': url});
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}
