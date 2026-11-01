import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:status_monitor/app_state.dart';
import 'package:status_monitor/services/system_service.dart';
import 'package:status_monitor/widgets/usage_chart.dart';
import 'hardware_info_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  Timer? _cpuTimer;
  Timer? _memTimer;
  Timer? _netTimer;

  double _activeCpuInterval = 0;
  double _activeMemInterval = 0;
  double _activeNetInterval = 0;

  bool _activeCpuEnabled = false;
  bool _activeMemEnabled = false;
  bool _activeNetEnabled = false;

  // Distinct simulation states for fallback
  double _simTimeCpu = 35.0;
  double _cpuTimeVelocity = 0.0;
  double _simFreqCpu = 18.0;
  double _simMem = 52.0;
  double _simDownSpeed = 18.0 * 1024.0;
  double _simUpSpeed = 6.0 * 1024.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _detectSystemTotalMemory();
      _initSeedData();
      _syncTimers();
      final state = context.read<AppState>();
      if (state.isStatusBarEnabled || state.isFloatingEnabled) {
        SystemService.syncFromAppState(state);
      }
    });
  }

  Future<void> _detectSystemTotalMemory() async {
    try {
      final memInfo = await SystemService.getMemoryInfo();
      if (memInfo.isNotEmpty && memInfo[0] > 0) {
        final totalGb = memInfo[0] / 1024.0;
        if (mounted) {
          context.read<AppState>().setTotalMemory(totalGb);
        }
      }
    } catch (_) {}
  }

  void _initSeedData() {
    final state = context.read<AppState>();
    for (int i = 0; i < AppState.maxDataPoints; i++) {
      _stepSimulatedCpu();
      state.addCpuData(_simTimeCpu, _simFreqCpu);
      state.addMemData(_nextSimulatedMem());
      _stepSimulatedNetwork();
      state.addNetData(_simDownSpeed, _simUpSpeed);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimers();
  }

  void _syncTimers() {
    final state = context.read<AppState>();

    // 1. Sync CPU Timer
    if (_activeCpuInterval != state.cpuInterval || _activeCpuEnabled != state.isCpuEnabled) {
      _cpuTimer?.cancel();
      _activeCpuInterval = state.cpuInterval;
      _activeCpuEnabled = state.isCpuEnabled;

      if (_activeCpuEnabled) {
        _cpuTimer = Timer.periodic(
          Duration(milliseconds: _activeCpuInterval.toInt()),
          (_) => _sampleCpu(),
        );
      }
    }

    // 2. Sync Memory Timer
    if (_activeMemInterval != state.memInterval || _activeMemEnabled != state.isMemEnabled) {
      _memTimer?.cancel();
      _activeMemInterval = state.memInterval;
      _activeMemEnabled = state.isMemEnabled;

      if (_activeMemEnabled) {
        _memTimer = Timer.periodic(
          Duration(milliseconds: _activeMemInterval.toInt()),
          (_) => _sampleMemory(),
        );
      }
    }

    // 3. Sync Network Timer
    if (_activeNetInterval != state.netInterval || _activeNetEnabled != state.isNetEnabled) {
      _netTimer?.cancel();
      _activeNetInterval = state.netInterval;
      _activeNetEnabled = state.isNetEnabled;

      if (_activeNetEnabled) {
        _netTimer = Timer.periodic(
          Duration(milliseconds: _activeNetInterval.toInt()),
          (_) => _sampleNetwork(),
        );
      }
    }
  }

  // Sample CPU: Both Time-Occupied (Jiffies/Idle) and Frequency-Weighted (time_in_state)
  Future<void> _sampleCpu() async {
    if (!mounted) return;
    final state = context.read<AppState>();
    if (!state.isCpuEnabled) return;

    try {
      final metrics = await SystemService.getCpuUsage();
      if (metrics != null &&
          metrics['timeBased'] != null &&
          metrics['freqWeighted'] != null &&
          metrics['timeBased']! >= 0 &&
          metrics['freqWeighted']! >= 0) {
        final timeBased = metrics['timeBased']!;
        final freqWeighted = metrics['freqWeighted']!;
        state.addCpuData(timeBased, freqWeighted);
        return;
      }
    } catch (_) {}

    _stepSimulatedCpu();
    state.addCpuData(_simTimeCpu, _simFreqCpu);
  }

  // Sample Memory: Native physical RAM or smooth fallback
  Future<void> _sampleMemory() async {
    if (!mounted) return;
    final state = context.read<AppState>();
    if (!state.isMemEnabled) return;

    try {
      final memInfo = await SystemService.getMemoryInfo();
      if (memInfo.length >= 2 && memInfo[0] > 0) {
        final totalMb = memInfo[0];
        final availMb = memInfo[1];
        state.setTotalMemory(totalMb / 1024.0);

        final usedMb = (totalMb - availMb).clamp(0, totalMb);
        final percent = (usedMb / totalMb) * 100.0;
        state.addMemData(percent);
        return;
      }
    } catch (_) {}

    state.addMemData(_nextSimulatedMem());
  }

  // Sample Network: Real TrafficStats with EMA or realistic dynamic flow
  Future<void> _sampleNetwork() async {
    if (!mounted) return;
    final state = context.read<AppState>();
    if (!state.isNetEnabled) return;

    try {
      final netData = await SystemService.getNetworkSpeed();
      if (netData != null && (netData['downSpeed']! >= 0 || netData['upSpeed']! >= 0)) {
        state.addNetData(netData['downSpeed']!, netData['upSpeed']!);
        return;
      }
    } catch (_) {}

    _stepSimulatedNetwork();
    state.addNetData(_simDownSpeed, _simUpSpeed);
  }

  // Realistic CPU load simulation generating two distinct curves
  void _stepSimulatedCpu() {
    final random = Random();
    _cpuTimeVelocity += (random.nextDouble() - 0.52) * 5.0;
    _cpuTimeVelocity *= 0.68;
    _simTimeCpu += _cpuTimeVelocity;

    if (random.nextDouble() < 0.06) {
      _simTimeCpu += (random.nextDouble() * 25.0);
    }
    _simTimeCpu = _simTimeCpu.clamp(3.0, 95.0);

    // Frequency-weighted tracks clock scaling ratio
    final clockScaleRatio = 0.32 + (_simTimeCpu / 100.0) * 0.55;
    final targetFreq = (_simTimeCpu * clockScaleRatio).clamp(2.0, 90.0);
    _simFreqCpu = (_simFreqCpu * 0.70) + (targetFreq * 0.30);
  }

  double _nextSimulatedMem() {
    final random = Random();
    final delta = (random.nextDouble() - 0.49) * 0.8;
    _simMem = (_simMem + delta).clamp(30.0, 88.0);
    return _simMem;
  }

  void _stepSimulatedNetwork() {
    final random = Random();
    double targetDown = 12.0 * 1024.0 + random.nextDouble() * 28.0 * 1024.0;
    double targetUp = 4.0 * 1024.0 + random.nextDouble() * 12.0 * 1024.0;

    if (random.nextDouble() < 0.07) {
      targetDown += (random.nextDouble() * 1.8 * 1024.0 * 1024.0);
    }

    _simDownSpeed = (_simDownSpeed * 0.75) + (targetDown * 0.25);
    _simUpSpeed = (_simUpSpeed * 0.80) + (targetUp * 0.20);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cpuTimer?.cancel();
    _memTimer?.cancel();
    _netTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncTimers();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _cpuTimer?.cancel();
      _cpuTimer = null;
      _memTimer?.cancel();
      _memTimer = null;
      _netTimer?.cancel();
      _netTimer = null;
      _activeCpuInterval = 0;
      _activeMemInterval = 0;
      _activeNetInterval = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isFreq = state.statusBarCpuMetric == "freq";

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.insights_rounded, size: 24),
            SizedBox(width: 8),
            Text(
              "StatusMonitor",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: "Hardware Details",
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HardwareInfoScreen()),
              );
            },
          ),
          Builder(
            builder: (ctx) => IconButton(
              tooltip: "Settings",
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
        ],
      ),
      endDrawer: const SettingsDrawer(),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // Quick Status Overview Bar
          _buildQuickOverview(context, state, isDark),
          const SizedBox(height: 14),

          // 1. CPU Line Chart (Metric dynamically adapts to settings)
          UsageChart(
            title: "CPU Usage",
            subtitle: isFreq
                ? "Frequency-Weighted vs. Time-Occupied"
                : "Time-Occupied vs. Frequency-Weighted",
            spots: isFreq ? state.cpuFreqSpots : state.cpuTimeSpots,
            secondarySpots: isFreq ? state.cpuTimeSpots : state.cpuFreqSpots,
            primaryLabel: isFreq ? "Freq-Weighted" : "Time-Occupied",
            secondaryLabel: isFreq ? "Time-Occupied" : "Freq-Weighted",
            tabPrimaryLabel: isFreq ? "Freq" : "Time",
            tabSecondaryLabel: isFreq ? "Time" : "Freq",
            currentValue: isFreq ? state.currentCpuFreqUsage : state.currentCpuTimeUsage,
            secondaryCurrentValue: isFreq ? state.currentCpuTimeUsage : state.currentCpuFreqUsage,
            minVal: isFreq ? state.minCpuFreqUsage : state.minCpuTimeUsage,
            maxVal: isFreq ? state.maxCpuFreqUsage : state.maxCpuTimeUsage,
            avgVal: isFreq ? state.avgCpuFreqUsage : state.avgCpuTimeUsage,
            secondaryMinVal: isFreq ? state.minCpuTimeUsage : state.minCpuFreqUsage,
            secondaryMaxVal: isFreq ? state.maxCpuTimeUsage : state.maxCpuFreqUsage,
            secondaryAvgVal: isFreq ? state.avgCpuTimeUsage : state.avgCpuFreqUsage,
            primaryColor: const Color(0xFF1E90FF),
            secondaryColor: const Color(0xFFFF9100),
            gradientColors: const [
              Color(0xFF0066FF),
              Color(0xFF1E90FF),
            ],
            secondaryGradientColors: const [
              Color(0xFFFF6D00),
              Color(0xFFFFAB00),
            ],
            icon: Icons.memory_rounded,
            unit: '%',
            isEnabled: state.isCpuEnabled,
          ),

          // 2. Memory Line Chart (with RAM in GB under Min/Avg/Peak)
          UsageChart(
            title: "Memory Usage",
            subtitle: "Physical RAM allocation & memory load",
            spots: state.memSpots,
            currentValue: state.currentMemUsage,
            minVal: state.minMemUsage,
            maxVal: state.maxMemUsage,
            avgVal: state.avgMemUsage,
            usedMemGb: state.usedMemGb,
            totalMemGb: state.totalMemGb,
            primaryColor: const Color(0xFFFF4081),
            gradientColors: const [
              Color(0xFF7928CA),
              Color(0xFFFF0080),
            ],
            icon: Icons.storage_rounded,
            unit: '%',
            isEnabled: state.isMemEnabled,
          ),

          // 3. Network Speed Line Chart (Download vs. Upload)
          UsageChart(
            title: "Network Speed",
            subtitle: "Real-time bandwidth throughput",
            spots: state.netDownSpots,
            secondarySpots: state.netUpSpots,
            primaryLabel: "Download",
            secondaryLabel: "Upload",
            currentValue: state.currentDownSpeedKb,
            secondaryCurrentValue: state.currentUpSpeedKb,
            formattedCurrentValue: state.currentDownSpeedFormatted,
            formattedSecondaryValue: state.currentUpSpeedFormatted,
            minVal: state.minDownSpeedKb,
            maxVal: state.maxDownSpeedKb,
            avgVal: state.avgDownSpeedKb,
            statFormatter: (kb) => AppState.formatSpeed(kb * 1024.0),
            primaryColor: const Color(0xFF00E676),
            secondaryColor: const Color(0xFF7C4DFF),
            gradientColors: const [
              Color(0xFF00B0FF),
              Color(0xFF00E676),
            ],
            secondaryGradientColors: const [
              Color(0xFF651FFF),
              Color(0xFFB388FF),
            ],
            icon: Icons.wifi_rounded,
            unit: ' KB/s',
            fixedMaxY: null,
            isEnabled: state.isNetEnabled,
          ),
        ],
      ),
    );
  }

  Widget _buildQuickOverview(BuildContext context, AppState state, bool isDark) {
    final isTimeMetric = state.statusBarCpuMetric == "time";
    final cpuVal = isTimeMetric ? state.currentCpuTimeUsage : state.currentCpuFreqUsage;
    final cpuTag = isTimeMetric ? "Time" : "Freq";
    final cpuStr = cpuVal.round().clamp(0, 100).toString().padLeft(3);
    final ramStr = state.usedMemGb.clamp(0.0, 99.9).toStringAsFixed(1).padLeft(4);
    final netStr = state.currentTotalSpeedFormatted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141820) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF00E676),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                "Live",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                "CPU($cpuTag): $cpuStr% | RAM: ${ramStr}G | NET: $netStr",
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsDrawer extends StatelessWidget {
  const SettingsDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Drawer(
      child: ListView(
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Icon(Icons.display_settings_rounded, color: Colors.cyanAccent, size: 36),
                SizedBox(height: 8),
                Text(
                  "Monitor Settings",
                  style: TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold),
                ),
                Text(
                  "Configure refresh rates & monitor",
                  style: TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),

          // Theme Settings
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode_rounded),
            title: const Text("OLED Dark Mode"),
            value: state.themeMode == ThemeMode.dark,
            onChanged: (v) => state.toggleTheme(v),
          ),

          const Divider(),

          // Status Bar Notification Section
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              "Status Bar Notification",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.amber),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_rounded),
            title: const Text("Status Bar Display"),
            subtitle: const Text("Edge-to-edge dynamic status icon", style: TextStyle(fontSize: 11)),
            value: state.isStatusBarEnabled,
            onChanged: (v) {
              state.updateStatusBarSettings(v, state.statusBarMode, state.statusBarCpuMetric);
              SystemService.syncFromAppState(state);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: state.statusBarMode,
              decoration: const InputDecoration(
                labelText: "Status Bar Icon Mode",
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(
                  value: "usage",
                  child: Text(
                    "Resource Usage (CPU / RAM)",
                    style: TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: "speed",
                  child: Text(
                    "Network Speed (Value / Unit)",
                    style: TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: "both",
                  child: Text(
                    "Both Icons (Dual Status Bar)",
                    style: TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: state.isStatusBarEnabled
                  ? (newMode) {
                      if (newMode != null) {
                        state.updateStatusBarSettings(state.isStatusBarEnabled, newMode, state.statusBarCpuMetric);
                        SystemService.syncFromAppState(state);
                      }
                    }
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          // CPU Metric Selection for Graph & Status Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: state.statusBarCpuMetric,
              decoration: const InputDecoration(
                labelText: "CPU Metric (Graph & Status Bar)",
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(
                  value: "time",
                  child: Text(
                    "Time-Occupied (Jiffies / Active)",
                    style: TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: "freq",
                  child: Text(
                    "Frequency-Weighted (DVFS / Capacity)",
                    style: TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (newMetric) {
                if (newMetric != null) {
                  state.updateStatusBarSettings(state.isStatusBarEnabled, state.statusBarMode, newMetric);
                  SystemService.syncFromAppState(state);
                }
              },
            ),
          ),

          const Divider(),

          // Floating Window (Overlay) Section
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              "Floating Window (Overlay)",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.orangeAccent),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.picture_in_picture_alt_rounded),
            title: const Text("Floating Window"),
            subtitle: const Text("Rounded square desktop overlay", style: TextStyle(fontSize: 11)),
            value: state.isFloatingEnabled,
            onChanged: (v) async {
              if (v) {
                final hasPermission = await SystemService.checkOverlayPermission();
                if (!hasPermission) {
                  if (context.mounted) {
                    final proceed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text("Overlay Permission Required"),
                        content: const Text(
                          "Displaying the floating window requires 'Display over other apps' permission. Would you like to grant it in System Settings?",
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text("Cancel"),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text("Open Settings"),
                          ),
                        ],
                      ),
                    );
                    if (proceed == true) {
                      await SystemService.requestOverlayPermission();
                    }
                  }
                  return;
                }
              }
              state.updateFloatingSettings(enabled: v);
              SystemService.syncFromAppState(state);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: state.floatingMode,
              decoration: const InputDecoration(
                labelText: "Floating Window Mode",
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(
                  value: "usage",
                  child: Text(
                    "Resource Usage (CPU / RAM)",
                    style: TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: "speed",
                  child: Text(
                    "Network Speed (Value / Unit)",
                    style: TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: "both",
                  child: Text(
                    "Both Windows (Side-by-side)",
                    style: TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: state.isFloatingEnabled
                  ? (newMode) {
                      if (newMode != null) {
                        state.updateFloatingSettings(mode: newMode);
                        SystemService.syncFromAppState(state);
                      }
                    }
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          _buildCustomSlider(
            context,
            "Floating Window Size",
            "${(state.floatingScale * 100).toStringAsFixed(state.floatingScale * 100 == (state.floatingScale * 100).round() ? 0 : 1)}%",
            state.floatingScale,
            0.05,
            0.15,
            4,
            state.isFloatingEnabled,
            (newScale) {
              final snapped = ((newScale / 0.025).round() * 0.025).clamp(0.05, 0.15);
              state.updateFloatingSettings(scale: snapped);
              SystemService.syncFromAppState(state);
            },
          ),
          _buildCustomSlider(
            context,
            "Floating Window Opacity",
            "${(state.floatingOpacity * 100).round()}%",
            state.floatingOpacity,
            0.30,
            1.00,
            7,
            state.isFloatingEnabled,
            (newOpacity) {
              final snapped = ((newOpacity / 0.10).round() * 0.10).clamp(0.30, 1.00);
              state.updateFloatingSettings(opacity: snapped);
              SystemService.syncFromAppState(state);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.touch_app_rounded),
            title: const Text("Tap to Open App"),
            subtitle: const Text("Launch application when tapping the window", style: TextStyle(fontSize: 11)),
            value: state.isFloatingTapEnabled,
            onChanged: state.isFloatingEnabled
                ? (v) {
                    state.updateFloatingSettings(tapEnabled: v);
                    SystemService.syncFromAppState(state);
                  }
                : null,
          ),

          const Divider(),

          // Resource Sampling (CPU & RAM) Section
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              "Resource Sampling (CPU & Memory)",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.cyan),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.memory_rounded),
            title: const Text("CPU Monitoring"),
            value: state.isCpuEnabled,
            onChanged: (v) {
              state.updateCpuSettings(v);
              SystemService.syncFromAppState(state);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.storage_rounded),
            title: const Text("Memory Monitoring"),
            value: state.isMemEnabled,
            onChanged: (v) {
              state.updateMemSettings(v);
              SystemService.syncFromAppState(state);
            },
          ),
          _buildSlider(
            context,
            "Resource Sampling Rate",
            state.resourceInterval,
            state.isCpuEnabled || state.isMemEnabled,
            (v) {
              state.updateResourceInterval(v);
              SystemService.syncFromAppState(state);
            },
          ),

          const Divider(),

          // Network Sampling Section
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              "Network Sampling",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF00E676)),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wifi_rounded),
            title: const Text("Network Monitoring"),
            value: state.isNetEnabled,
            onChanged: (v) {
              state.updateNetSettings(v, state.netInterval);
              SystemService.syncFromAppState(state);
            },
          ),
          _buildSlider(
            context,
            "Sampling Rate",
            state.netInterval,
            state.isNetEnabled,
            (v) {
              state.updateNetSettings(state.isNetEnabled, v);
              SystemService.syncFromAppState(state);
            },
          ),

          const Divider(),

          // About Section
          _buildAboutSection(context),
        ],
      ),
    );
  }

  Widget _buildAboutSection(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const githubUrl = "https://github.com/yingongsui/StatusMonitor";

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "About",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.purpleAccent,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Image.asset(
                'assets/app_icon_monochrome.png',
                width: 36,
                height: 36,
                //color: isDark ? Colors.cyanAccent : const Color(0xFF0072FF),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Status Monitor",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    Text(
                      "v1.0.0 • Real-time System Monitor",
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            "A lightweight, real-time Android system resource monitor and floating window monitor built with Flutter.",
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
          const SizedBox(height: 12),
          _buildFeatureItem(Icons.memory_rounded, const Color(0xFF1E90FF), "CPU", "Time-Occupied & Freq-Weighted", isDark),
          const SizedBox(height: 6),
          _buildFeatureItem(Icons.storage_rounded, const Color(0xFFFF4081), "RAM", "Physical memory allocation & peak stats", isDark),
          const SizedBox(height: 6),
          _buildFeatureItem(Icons.wifi_rounded, const Color(0xFF00E676), "Network", "Real-time upload & download throughput", isDark),
          const SizedBox(height: 6),
          _buildFeatureItem(Icons.picture_in_picture_alt_rounded, const Color(0xFFFF9100), "Overlay", "Floating window with screen-off sleep", isDark),
          const SizedBox(height: 14),
          InkWell(
            onTap: () => SystemService.openUrl(githubUrl),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isDark ? Colors.white12 : Colors.black12,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.code_rounded,
                    size: 18,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "GitHub Repository",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        Text(
                          githubUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    tooltip: "Copy URL",
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(6),
                    onPressed: () {
                      Clipboard.setData(const ClipboardData(text: githubUrl));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Repository URL copied to clipboard"),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildFeatureItem(IconData icon, Color color, String title, String desc, bool isDark) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
              children: [
                TextSpan(
                  text: "$title: ",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(
                  text: desc,
                  style: TextStyle(
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSlider(
    BuildContext context,
    String label,
    double value,
    bool isEnabled,
    Function(double) onChanged,
  ) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: isEnabled ? null : Colors.grey,
                ),
              ),
              Text(
                "${value.toInt()} ms",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  color: isEnabled ? Theme.of(context).colorScheme.primary : Colors.grey,
                ),
              ),
            ],
          ),
        ),
        Slider(
          min: 500,
          max: 3000,
          divisions: 5,
          value: value,
          onChanged: isEnabled ? onChanged : null,
        ),
      ],
    );
  }

  Widget _buildCustomSlider(
    BuildContext context,
    String label,
    String formattedValue,
    double value,
    double min,
    double max,
    int? divisions,
    bool isEnabled,
    Function(double) onChanged,
  ) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: isEnabled ? null : Colors.grey,
                ),
              ),
              Text(
                formattedValue,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  color: isEnabled ? Theme.of(context).colorScheme.primary : Colors.grey,
                ),
              ),
            ],
          ),
        ),
        Slider(
          min: min,
          max: max,
          divisions: divisions,
          value: value.clamp(min, max),
          onChanged: isEnabled ? onChanged : null,
        ),
      ],
    );
  }
}
