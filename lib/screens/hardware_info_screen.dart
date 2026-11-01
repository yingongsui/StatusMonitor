import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class HardwareInfoScreen extends StatefulWidget {
  const HardwareInfoScreen({super.key});

  @override
  State<HardwareInfoScreen> createState() => _HardwareInfoScreenState();
}

class _HardwareInfoScreenState extends State<HardwareInfoScreen>
    with WidgetsBindingObserver {
  static const platform = MethodChannel('com.example.app/hardware');
  Timer? _pollingTimer;
  Map<String, dynamic>? _hardwareData;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _stopPolling();
    }
  }

  void _startPolling() {
    _stopPolling();
    _fetchHardwareInfo();
    _pollingTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _fetchHardwareInfo(isPeriodic: true),
    );
  }

  void _stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  Future<void> _fetchHardwareInfo({bool isPeriodic = false}) async {
    try {
      final Map<dynamic, dynamic> result =
          await platform.invokeMethod('getHardwareInfo');
      if (!mounted) return;
      setState(() {
        _hardwareData = Map<String, dynamic>.from(result);
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!isPeriodic) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isLoading && _hardwareData == null) {
      return Scaffold(
        appBar: AppBar(title: const Text("Hardware Details")),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_errorMessage != null && _hardwareData == null) {
      return Scaffold(
        appBar: AppBar(title: const Text("Hardware Details")),
        body: Center(child: Text("Error: $_errorMessage")),
      );
    }

    final data = _hardwareData ?? {};
    final List<dynamic> cores = data['cores'] ?? [];
    final String mem = data['memory'] ?? "Unknown";

    return Scaffold(
      appBar: AppBar(
        title: const Text("Hardware Details"),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF00E676).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt_rounded, size: 14, color: Color(0xFF00E676)),
                SizedBox(width: 4),
                Text(
                  "LIVE",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00E676),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // Total Physical Memory Card
          Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF161A22) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.06),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.storage_rounded, color: Colors.blue),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Total Physical Memory",
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          SizedBox(height: 2),
                          Text(
                            "RAM detected from /proc/meminfo",
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      mem,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // CPU Cores Section Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "CPU Cores Status",
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E90FF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      "${cores.length} Cores",
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E90FF),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // CPU Cores List (Directly displayed, no folding / expansion)
              ...cores.map((core) {
                final c = Map<String, String>.from(core);
                final coreId = c['id'] ?? 'Core';
                final freq = c['freq'] ?? '0 MHz / 0 MHz';
                final arch = c['arch'] ?? 'ARMv8/v9';

                // Calculate progress ratio if available
                double ratio = 0.5;
                final curMhz = double.tryParse(c['curFreqMhz'] ?? '');
                final maxMhz = double.tryParse(c['maxFreqMhz'] ?? '');
                if (curMhz != null && maxMhz != null && maxMhz > 0) {
                  ratio = (curMhz / maxMhz).clamp(0.0, 1.0);
                }

                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF161A22) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.06),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Core Title & Online Status
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E90FF).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.memory_rounded, color: Color(0xFF1E90FF), size: 20),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                coreId,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00E676).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              "ONLINE",
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF00E676),
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // Clock Frequency
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.speed_rounded, size: 16, color: Colors.grey),
                              SizedBox(width: 6),
                              Text(
                                "Clock Speed",
                                style: TextStyle(fontSize: 13, color: Colors.grey),
                              ),
                            ],
                          ),
                          Text(
                            freq,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 8),

                      // Frequency Progress Bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 5,
                          backgroundColor: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF1E90FF)),
                        ),
                      ),

                      const SizedBox(height: 10),

                      // Architecture
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            "Architecture",
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          Text(
                            arch,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
    );
  }
}
