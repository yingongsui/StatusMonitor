import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';

enum ChartDisplayMode { both, primary, secondary }

class UsageChart extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<FlSpot>? spots;
  final List<FlSpot>? secondarySpots;
  final String primaryLabel;
  final String secondaryLabel;
  final double? currentValue;
  final double? secondaryCurrentValue;
  final String? formattedCurrentValue;
  final String? formattedSecondaryValue;
  final double? minVal;
  final double? maxVal;
  final double? avgVal;
  final double? secondaryMinVal;
  final double? secondaryMaxVal;
  final double? secondaryAvgVal;
  final String? tabPrimaryLabel;
  final String? tabSecondaryLabel;
  final String Function(double)? statFormatter;
  final Color primaryColor;
  final Color secondaryColor;
  final List<Color>? gradientColors;
  final List<Color>? secondaryGradientColors;
  final IconData icon;
  final String unit;
  final bool isEnabled;
  final double? fixedMaxY; // null for auto-scaling (e.g. network speed), 100 for percentage
  final bool isCurved; // false = direct polyline to prevent 100% clipping; true = spline

  // Memory specific GB indicators
  final double? usedMemGb;
  final double? totalMemGb;

  const UsageChart({
    super.key,
    required this.title,
    this.subtitle,
    this.spots,
    this.secondarySpots,
    this.primaryLabel = "Primary",
    this.secondaryLabel = "Secondary",
    this.tabPrimaryLabel,
    this.tabSecondaryLabel,
    this.currentValue,
    this.secondaryCurrentValue,
    this.formattedCurrentValue,
    this.formattedSecondaryValue,
    this.minVal,
    this.maxVal,
    this.avgVal,
    this.secondaryMinVal,
    this.secondaryMaxVal,
    this.secondaryAvgVal,
    this.statFormatter,
    this.primaryColor = const Color(0xFF1E90FF),
    this.secondaryColor = const Color(0xFFFF9100),
    this.gradientColors,
    this.secondaryGradientColors,
    this.icon = Icons.speed_rounded,
    this.unit = '%',
    this.isEnabled = true,
    this.fixedMaxY = 100.0,
    this.isCurved = false, // Direct straight polyline
    this.usedMemGb,
    this.totalMemGb,
  });

  @override
  State<UsageChart> createState() => _UsageChartState();
}

class _UsageChartState extends State<UsageChart> {
  ChartDisplayMode _displayMode = ChartDisplayMode.both;

  Color _getStatusColor(double value) {
    if (widget.fixedMaxY != null && widget.fixedMaxY! <= 100) {
      if (value >= 85) return const Color(0xFFFF5252);
      if (value >= 60) return const Color(0xFFFFAB00);
      return const Color(0xFF00E676);
    }
    return widget.primaryColor;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final state = context.watch<AppState>();

    final isMemory = widget.title.toLowerCase().contains("memory");
    final isNetwork = widget.title.toLowerCase().contains("network");

    final effectiveSpots = widget.spots ??
        (isNetwork
            ? state.netDownSpots
            : (isMemory ? state.memSpots : state.cpuTimeSpots));

    final effectiveSecSpots = widget.secondarySpots ??
        (isNetwork
            ? state.netUpSpots
            : (isMemory ? null : state.cpuFreqSpots));

    final effectiveCurrent = widget.currentValue ??
        (isNetwork
            ? state.currentDownSpeedKb
            : (isMemory ? state.currentMemUsage : state.currentCpuTimeUsage));

    final effectiveSecCurrent = widget.secondaryCurrentValue ??
        (isNetwork
            ? state.currentUpSpeedKb
            : (isMemory ? 0.0 : state.currentCpuFreqUsage));

    final effectiveMin = widget.minVal ??
        (isNetwork
            ? state.minDownSpeedKb
            : (isMemory ? state.minMemUsage : state.minCpuTimeUsage));

    final effectiveMax = widget.maxVal ??
        (isNetwork
            ? state.maxDownSpeedKb
            : (isMemory ? state.maxMemUsage : state.maxCpuTimeUsage));

    final effectiveAvg = widget.avgVal ??
        (isNetwork
            ? state.avgDownSpeedKb
            : (isMemory ? state.avgMemUsage : state.avgCpuTimeUsage));

    final effectiveEnabled = widget.isEnabled &&
        (isNetwork
            ? state.isNetEnabled
            : (isMemory ? state.isMemEnabled : state.isCpuEnabled));

    final effectiveUsedGb = widget.usedMemGb ?? (isMemory ? state.usedMemGb : null);
    final effectiveTotalGb = widget.totalMemGb ?? (isMemory ? state.totalMemGb : null);

    final List<Color> primGrad = widget.gradientColors ?? [
      widget.primaryColor.withValues(alpha: 0.8),
      widget.primaryColor,
    ];

    final List<Color> secGrad = widget.secondaryGradientColors ?? [
      widget.secondaryColor.withValues(alpha: 0.8),
      widget.secondaryColor,
    ];

    final isSecondary = _displayMode == ChartDisplayMode.secondary;
    final activeCurrent = isSecondary ? effectiveSecCurrent : effectiveCurrent;
    final activeFormatted = isSecondary ? widget.formattedSecondaryValue : widget.formattedCurrentValue;
    final activeColor = isSecondary ? widget.secondaryColor : _getStatusColor(activeCurrent);

    final activeMin = isSecondary ? (widget.secondaryMinVal ?? effectiveMin) : effectiveMin;
    final activeMax = isSecondary ? (widget.secondaryMaxVal ?? effectiveMax) : effectiveMax;
    final activeAvg = isSecondary ? (widget.secondaryAvgVal ?? effectiveAvg) : effectiveAvg;

    _getStatusColor(effectiveCurrent);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.white54 : Colors.black45;
    final gridLineColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    final hasDual = effectiveSecSpots != null;

    // Calculate dynamic maxY for auto-scaling charts (e.g. network speed)
    double calculatedMaxY = 100.0;
    if (widget.fixedMaxY != null) {
      calculatedMaxY = widget.fixedMaxY!;
    } else {
      double maxSpotVal = 10.0;
      for (final s in effectiveSpots) {
        if (s.y > maxSpotVal) maxSpotVal = s.y;
      }
      if (effectiveSecSpots != null) {
        for (final s in effectiveSecSpots) {
          if (s.y > maxSpotVal) maxSpotVal = s.y;
        }
      }
      calculatedMaxY = max(20.0, maxSpotVal * 1.25);
    }

    // Build chart lines: Direct straight polyline prevents 100% curve clipping
    final List<LineChartBarData> lines = [];

    if (effectiveEnabled && effectiveSpots.isNotEmpty) {
      if (!hasDual ||
          _displayMode == ChartDisplayMode.both ||
          _displayMode == ChartDisplayMode.primary) {
        lines.add(
          LineChartBarData(
            spots: effectiveSpots,
            isCurved: false,
            curveSmoothness: 0.0,
            barWidth: 2.8,
            isStrokeCapRound: true,
            gradient: LinearGradient(colors: primGrad),
            dotData: FlDotData(
              show: true,
              checkToShowDot: (spot, barData) => spot.x == barData.spots.last.x,
              getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
                radius: 4.5,
                color: primGrad.last,
                strokeWidth: 2,
                strokeColor: isDark ? Colors.black : Colors.white,
              ),
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  primGrad.last.withValues(alpha: hasDual ? 0.18 : 0.30),
                  primGrad.first.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        );
      }

      if (hasDual &&
          (_displayMode == ChartDisplayMode.both ||
              _displayMode == ChartDisplayMode.secondary)) {
        lines.add(
          LineChartBarData(
            spots: effectiveSecSpots,
            isCurved: false,
            curveSmoothness: 0.0,
            barWidth: 2.5,
            isStrokeCapRound: true,
            gradient: LinearGradient(colors: secGrad),
            dotData: FlDotData(
              show: true,
              checkToShowDot: (spot, barData) => spot.x == barData.spots.last.x,
              getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
                radius: 4.0,
                color: secGrad.last,
                strokeWidth: 2,
                strokeColor: isDark ? Colors.black : Colors.white,
              ),
            ),
            belowBarData: BarAreaData(
              show: _displayMode == ChartDisplayMode.secondary,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  secGrad.last.withValues(alpha: 0.25),
                  secGrad.first.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        );
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161A22) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? widget.primaryColor.withValues(alpha: 0.22)
              : Colors.black.withValues(alpha: 0.06),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? widget.primaryColor.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- Header: Title & Real-time Readouts ---
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        primGrad.first.withValues(alpha: 0.2),
                        primGrad.last.withValues(alpha: 0.35),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(widget.icon, color: primGrad.last, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle ??
                            (effectiveEnabled
                                ? "Active real-time telemetry"
                                : "Monitoring paused"),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: subTextColor,
                        ),
                      ),
                    ],
                  ),
                ),
                // Real-time Number Display (Constrained min-width prevents left subtitle from wrapping/bouncing)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: isNetwork ? 108.0 : 86.0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            effectiveEnabled
                                ? (activeFormatted ??
                                    activeCurrent.toStringAsFixed(1))
                                : "--",
                            style: TextStyle(
                              fontSize: isNetwork ? 19 : 24,
                              fontWeight: FontWeight.w900,
                              fontFamily: 'monospace',
                              color: effectiveEnabled ? activeColor : subTextColor,
                            ),
                          ),
                          if (activeFormatted == null) ...[
                            const SizedBox(width: 2),
                            Text(
                              widget.unit,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: subTextColor,
                              ),
                            ),
                          ],
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: effectiveEnabled ? activeColor : Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            effectiveEnabled ? "LIVE" : "PAUSED",
                            style: TextStyle(
                              fontSize: 10,
                              color: effectiveEnabled ? activeColor : Colors.grey,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // --- Dual Metric Legend & Selector Tabs ---
            if (hasDual) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      _buildLegendDot(
                          widget.primaryColor, widget.primaryLabel, textColor),
                      const SizedBox(width: 12),
                      _buildLegendDot(
                          widget.secondaryColor, widget.secondaryLabel, textColor),
                    ],
                  ),
                  Container(
                    height: 26,
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white10
                          : Colors.black.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildModeTab("Both", ChartDisplayMode.both),
                        _buildModeTab(
                            widget.tabPrimaryLabel ?? (isNetwork ? "Down" : "Time"),
                            ChartDisplayMode.primary),
                        _buildModeTab(
                            widget.tabSecondaryLabel ?? (isNetwork ? "Up" : "Freq"),
                            ChartDisplayMode.secondary),
                      ],
                    ),
                  ),
                ],
              ),
              if (effectiveEnabled && !isNetwork)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    "${widget.primaryLabel}: ${effectiveCurrent.toStringAsFixed(1)}%  |  ${widget.secondaryLabel}: ${effectiveSecCurrent.toStringAsFixed(1)}%",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: subTextColor, fontFamily: 'monospace'),
                  ),
                ),
              if (effectiveEnabled && isNetwork)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    "↓ ${state.currentDownSpeedFormatted}  |  ↑ ${state.currentUpSpeedFormatted}",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: subTextColor, fontFamily: 'monospace'),
                  ),
                ),
            ],

            const SizedBox(height: 14),

            // --- Chart Canvas (Direct Polyline, clipData: none prevents 100% cutoff) ---
            SizedBox(
              height: 174,
              child: effectiveSpots.isEmpty
                  ? Center(
                      child: Text("No Data",
                          style: TextStyle(color: subTextColor)))
                  : Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: LineChart(
                      LineChartData(
                        minY: 0,
                        maxY: calculatedMaxY,
                        minX: 0,
                        maxX: (effectiveSpots.length - 1).toDouble(),
                        clipData: const FlClipData.none(), // Do not clip 100% tops or border strokes
                        gridData: FlGridData(
                          show: true,
                          drawVerticalLine: false,
                          horizontalInterval: calculatedMaxY / 4.0,
                          getDrawingHorizontalLine: (value) => FlLine(
                            color: gridLineColor,
                            strokeWidth: 1,
                            dashArray: [4, 4],
                          ),
                        ),
                        titlesData: FlTitlesData(
                          show: true,
                          topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          bottomTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 42,
                              interval: calculatedMaxY / 2.0,
                              getTitlesWidget: (value, meta) {
                                String label;
                                if (isNetwork) {
                                  label = value >= 1024
                                      ? "${(value / 1024).toStringAsFixed(0)}M"
                                      : "${value.toInt()}K";
                                } else {
                                  label = "${value.toInt()}%";
                                }

                                return Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Text(
                                    label,
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      color: subTextColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        borderData: FlBorderData(show: false),
                        lineTouchData: LineTouchData(
                          enabled: true,
                          handleBuiltInTouches: true,
                          touchTooltipData: LineTouchTooltipData(
                            getTooltipItems: (touchedSpots) {
                              return touchedSpots.map((spot) {
                                final isSec = spot.barIndex == 1;
                                final name = isSec
                                    ? widget.secondaryLabel
                                    : widget.primaryLabel;

                                String valStr;
                                if (isNetwork) {
                                  valStr = spot.y >= 1024
                                      ? "${(spot.y / 1024).toStringAsFixed(2)} MB/s"
                                      : "${spot.y.toStringAsFixed(1)} KB/s";
                                } else {
                                  valStr =
                                      "${spot.y.toStringAsFixed(1)}${widget.unit}";
                                }

                                return LineTooltipItem(
                                  '$name: $valStr',
                                  TextStyle(
                                    color: isSec
                                        ? widget.secondaryColor
                                        : widget.primaryColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                  ),
                                );
                              }).toList();
                            },
                          ),
                        ),
                        lineBarsData: lines,
                      ),
                      duration: Duration.zero, // Disable fl_chart implicit animation to prevent flashing
                    ),
                  ),
            ),

            const SizedBox(height: 14),

            // --- Bottom Stats (Min / Avg / Peak) ---
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.04)
                    : Colors.black.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatItem("📉 Min", activeMin, widget.unit, subTextColor,
                      textColor, widget.statFormatter),
                  Container(width: 1, height: 16, color: gridLineColor),
                  _buildStatItem("📊 Avg", activeAvg, widget.unit, subTextColor,
                      textColor, widget.statFormatter),
                  Container(width: 1, height: 16, color: gridLineColor),
                  _buildStatItem("📈 Peak", activeMax, widget.unit, subTextColor,
                      textColor, widget.statFormatter),
                ],
              ),
            ),

            // --- Memory Capacity in GB below Min / Avg / Peak ---
            if (isMemory && effectiveUsedGb != null && effectiveTotalGb != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1B1F2A)
                      : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDark
                        ? primGrad.last.withValues(alpha: 0.22)
                        : Colors.black.withValues(alpha: 0.06),
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.pie_chart_outline_rounded,
                                size: 16, color: primGrad.last),
                            const SizedBox(width: 6),
                            Text(
                              "Physical RAM Usage",
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          "${effectiveUsedGb.toStringAsFixed(2)} GB / ${effectiveTotalGb.toStringAsFixed(2)} GB",
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                            color: primGrad.last,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: LinearProgressIndicator(
                        value: (effectiveUsedGb /
                                (effectiveTotalGb > 0 ? effectiveTotalGb : 1))
                            .clamp(0.0, 1.0),
                        minHeight: 7,
                        backgroundColor: isDark
                            ? Colors.white10
                            : Colors.black.withValues(alpha: 0.08),
                        valueColor: AlwaysStoppedAnimation<Color>(primGrad.last),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "Used: ${effectiveUsedGb.toStringAsFixed(2)} GB (${((effectiveUsedGb / (effectiveTotalGb > 0 ? effectiveTotalGb : 1)) * 100).toStringAsFixed(1)}%)",
                          style: TextStyle(fontSize: 10, color: subTextColor),
                        ),
                        Text(
                          "Free: ${(effectiveTotalGb - effectiveUsedGb).clamp(0.0, effectiveTotalGb).toStringAsFixed(2)} GB",
                          style: TextStyle(fontSize: 10, color: subTextColor),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLegendDot(Color color, String label, Color textColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: textColor),
        ),
      ],
    );
  }

  Widget _buildModeTab(String text, ChartDisplayMode mode) {
    final isSelected = _displayMode == mode;
    return GestureDetector(
      onTap: () => setState(() => _displayMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 10,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.white : Colors.grey,
          ),
        ),
      ),
    );
  }

  Widget _buildStatItem(
    String label,
    double value,
    String unit,
    Color subTextColor,
    Color textColor,
    String Function(double)? formatter,
  ) {
    final displayStr = formatter != null
        ? formatter(value)
        : "${value.toStringAsFixed(1)}$unit";

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          "$label: ",
          style: TextStyle(
            fontSize: 11,
            color: subTextColor,
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          displayStr,
          style: TextStyle(
            fontSize: 11,
            color: textColor,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}
