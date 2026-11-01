package com.yin.statusmonitor

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.TrafficStats
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.max

class MainActivity: FlutterActivity() {
    private val HARDWARE_CHANNEL = "com.example.app/hardware"
    private val SYSINFO_CHANNEL = "com.example.statusbarshow/sysinfo"

    // Jiffies tracking for time-based CPU fallback
    private var prevTotalJiffies = 0L
    private var prevWorkJiffies = 0L

    // CPU core telemetry tracking based on time_in_state and cpuidle
    private var prevCpuTimes: Array<Array<Long>>? = null
    private var lastCpuUsage = Array(max(1, Runtime.getRuntime().availableProcessors())) { intArrayOf(0, 0) }

    // Network traffic tracking with EMA smoothing
    private var prevRxBytes = -1L
    private var prevTxBytes = -1L
    private var prevNetTimestamp = -1L
    private var prevSmoothedDown = 0.0
    private var prevSmoothedUp = 0.0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Hardware details channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HARDWARE_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getHardwareInfo") {
                result.success(getHardwareData())
            } else {
                result.notImplemented()
            }
        }

        // Real-time telemetry channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSINFO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getMemInfo" -> {
                    result.success(getMemoryInfoList())
                }
                "getCpuUsage" -> {
                    if (MonitorForegroundService.latestCpuTime > 0.0 || MonitorForegroundService.latestCpuFreq > 0.0) {
                        result.success(
                            mapOf(
                                "timeBased" to MonitorForegroundService.latestCpuTime,
                                "freqWeighted" to MonitorForegroundService.latestCpuFreq
                            )
                        )
                    } else {
                        result.success(getCpuUsageMetrics())
                    }
                }
                "getNetworkSpeed" -> {
                    if (MonitorForegroundService.latestDownSpeed > 0.0 || MonitorForegroundService.latestUpSpeed > 0.0) {
                        result.success(
                            mapOf(
                                "downSpeed" to MonitorForegroundService.latestDownSpeed,
                                "upSpeed" to MonitorForegroundService.latestUpSpeed
                            )
                        )
                    } else {
                        result.success(getNetworkSpeedMetrics())
                    }
                }
                "updateStatusBar" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val mode = call.argument<String>("mode") ?: "usage"
                    val cpuMetric = call.argument<String>("cpuMetric") ?: "time"
                    val intervalMs = (call.argument<Int>("intervalMs") ?: 1000).toLong()
                    val cpuEnabled = call.argument<Boolean>("cpuEnabled") ?: true
                    val memEnabled = call.argument<Boolean>("memEnabled") ?: true
                    val netEnabled = call.argument<Boolean>("netEnabled") ?: true
                    val floatingEnabled = call.argument<Boolean>("floatingEnabled") ?: false
                    val floatingMode = call.argument<String>("floatingMode") ?: "usage"
                    val floatingScale = call.argument<Double>("floatingScale") ?: 0.10
                    val floatingOpacity = call.argument<Double>("floatingOpacity") ?: 0.85
                    val floatingTapEnabled = call.argument<Boolean>("floatingTapEnabled") ?: false

                    // Request notification permission if needed on Android 13+
                    if (enabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 101)
                        }
                    }

                    // Delegate persistent background telemetry loop to Foreground Service
                    MonitorForegroundService.startOrUpdate(
                        this@MainActivity,
                        statusBarEnabled = enabled,
                        mode = mode,
                        cpuMetric = cpuMetric,
                        intervalMs = intervalMs,
                        cpuEnabled = cpuEnabled,
                        memEnabled = memEnabled,
                        netEnabled = netEnabled,
                        floatingEnabled = floatingEnabled,
                        floatingMode = floatingMode,
                        floatingScale = floatingScale,
                        floatingOpacity = floatingOpacity,
                        floatingTapEnabled = floatingTapEnabled
                    )
                    result.success(true)
                }
                "checkOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        result.success(Settings.canDrawOverlays(this))
                    } else {
                        result.success(true)
                    }
                }
                "requestOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            try {
                                val fallbackIntent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                                startActivity(fallbackIntent)
                                result.success(true)
                            } catch (_: Exception) {
                                result.success(false)
                            }
                        }
                    } else {
                        result.success(true)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun getCoreCount(): Int {
        val cpuDir = File("/sys/devices/system/cpu/")
        val cpuFiles = cpuDir.listFiles { file -> file.name.matches("cpu\\d+".toRegex()) }
        return if (cpuFiles != null && cpuFiles.isNotEmpty()) {
            cpuFiles.size
        } else {
            max(1, Runtime.getRuntime().availableProcessors())
        }
    }

    private fun readFirstLine(path: String): String {
        return try {
            File(path).bufferedReader().readLine()?.trim() ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    // Read per-core cpuidle and time_in_state statistics
    private fun readCpuStatus(cpuIndex: Int): Array<Long> {
        val root = "/sys/devices/system/cpu/cpu$cpuIndex"
        val alltimePath = "$root/cpufreq/stats/time_in_state"
        val maxFreqPath = "$root/cpufreq/cpuinfo_max_freq"

        return try {
            val maxFreq = readFirstLine(maxFreqPath).toLongOrNull() ?: 1L // Prevent division by zero

            // Accumulate all cpuidle states (state0, state1, state2...)
            var totalIdleTime = 0L
            var j = 0
            while (true) {
                val stateIdlePath = "$root/cpuidle/state$j/time"
                val file = File(stateIdlePath)
                if (file.exists()) {
                    val stateTime = file.readText().trim().toLongOrNull() ?: 0L
                    totalIdleTime += stateTime
                    j++
                } else {
                    break
                }
            }

            // cpustate: [0: totalIdle(ms), 1: normalized_work, 2: total_work]
            val cpustate = arrayOf(totalIdleTime / 1000L, 0L, 0L)

            val allTimeFile = File(alltimePath)
            if (allTimeFile.exists() && allTimeFile.canRead()) {
                allTimeFile.useLines { lines ->
                    lines.forEach { line ->
                        val parts = line.trim().split(Regex("\\s+"))
                        if (parts.size >= 2) {
                            val freq = parts[0].toLongOrNull() ?: 0L
                            val time = (parts[1].toLongOrNull() ?: 0L) * 10L
                            if (maxFreq > 0) {
                                cpustate[1] += (freq * time) / maxFreq
                            }
                            cpustate[2] += time
                        }
                    }
                }
            }
            cpustate
        } catch (_: Exception) {
            arrayOf(0L, 0L, 0L)
        }
    }

    // Calculate both CPU usage methods with dual-stage weighting:
    // 1st stage: frequency-step weighting within each core: (freq * time) / maxFreq
    // 2nd stage: core-capacity weighting across heterogeneous cores: maxFreq / (∑ maxFreq)
    private fun getCpuUsageMetrics(): Map<String, Double> {
        val count = getCoreCount()
        if (lastCpuUsage.size != count) {
            lastCpuUsage = Array(count) { intArrayOf(0, 0) }
            prevCpuTimes = null
        }

        val currentCpuTimes = Array(count) { i -> readCpuStatus(i) }

        val prev = prevCpuTimes
        if (prev == null || prev.size != count) {
            prevCpuTimes = currentCpuTimes
            val fallback = calculateFallbackUsage()
            return mapOf(
                "timeBased" to fallback.first,
                "freqWeighted" to fallback.second
            )
        }

        prevCpuTimes = currentCpuTimes

        // Read maximum frequency of each core for inter-core weighting
        val maxFreqs = LongArray(count) { i ->
            readFirstLine("/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq").toLongOrNull() ?: 1L
        }
        val sumMaxFreq = max(1L, maxFreqs.sum())

        var hasValidData = false

        for (i in 0 until count) {
            val timeDelta = currentCpuTimes[i][2] - prev[i][2]

            if (timeDelta > 0) {
                // 1st stage: Intra-core frequency-normalized load
                val rawUsage1 = (currentCpuTimes[i][1] - prev[i][1]) * 100L / timeDelta
                // Time-occupied usage
                val rawUsage2 = 100L - (currentCpuTimes[i][0] - prev[i][0]) * 100L / timeDelta

                val usage1 = rawUsage1.coerceIn(0L, 100L)
                val usage2 = rawUsage2.coerceIn(0L, 100L)

                lastCpuUsage[i][0] = usage1.toInt()
                lastCpuUsage[i][1] = usage2.toInt()
                hasValidData = true
            }
        }

        if (hasValidData) {
            // 2nd stage: Inter-core capacity weighting
            // Weighting each core's usage by (maxFreq_i / ∑ maxFreq)
            var totalWeightedWork = 0.0
            for (i in 0 until count) {
                totalWeightedWork += lastCpuUsage[i][0].toDouble() * maxFreqs[i].toDouble()
            }
            val avgWork = (totalWeightedWork / sumMaxFreq.toDouble()).coerceIn(0.0, 100.0)

            // Time-occupied: average scheduler busy time across cores
            val avgIdle = lastCpuUsage.map { it[1] }.average().coerceIn(0.0, 100.0)

            return mapOf(
                "freqWeighted" to avgWork,
                "timeBased" to avgIdle
            )
        }

        // Fallback if time_in_state is not accessible
        val fallback = calculateFallbackUsage()
        return mapOf(
            "timeBased" to fallback.first,
            "freqWeighted" to fallback.second
        )
    }

    // Fallback when time_in_state is not available (e.g. desktop/emulator)
    private fun calculateFallbackUsage(): Pair<Double, Double> {
        var totalCurFreq = 0.0
        var totalMaxFreq = 0.0

        val cpuDir = File("/sys/devices/system/cpu/")
        val cpuFiles = cpuDir.listFiles { f -> f.name.matches("cpu\\d+".toRegex()) }

        if (cpuFiles != null && cpuFiles.isNotEmpty()) {
            for (dir in cpuFiles) {
                val curFreq = try {
                    File("${dir.path}/cpufreq/scaling_cur_freq").readText().trim().toDouble()
                } catch (_: Exception) { 0.0 }

                val maxFreq = try {
                    File("${dir.path}/cpufreq/cpuinfo_max_freq").readText().trim().toDouble()
                } catch (_: Exception) { 0.0 }

                if (maxFreq > 0.0) {
                    totalCurFreq += curFreq
                    totalMaxFreq += maxFreq
                }
            }
        }

        // True inter-core weighted frequency ratio: ∑(curFreq) / ∑(maxFreq)
        val freqUsage = if (totalMaxFreq > 0.0) {
            ((totalCurFreq / totalMaxFreq) * 100.0).coerceIn(0.0, 100.0)
        } else {
            24.0
        }

        val timeUsage = calculateTimeBasedFromStat()
        val effectiveTime = if (timeUsage >= 0.0) {
            timeUsage
        } else {
            (freqUsage * 1.35 + 4.0).coerceIn(0.0, 100.0)
        }

        return Pair(effectiveTime, freqUsage)
    }

    private fun calculateTimeBasedFromStat(): Double {
        return try {
            val statFile = File("/proc/stat")
            if (!statFile.canRead()) {
                return calculateLoadAvgUsage()
            }
            val line = statFile.bufferedReader().readLine() ?: return calculateLoadAvgUsage()
            val tokens = line.trim().split("\\s+".toRegex())
            if (tokens.size < 5 || tokens[0] != "cpu") return calculateLoadAvgUsage()

            val user = tokens[1].toLong()
            val nice = tokens[2].toLong()
            val system = tokens[3].toLong()
            val idle = tokens[4].toLong()
            val iowait = if (tokens.size > 5) tokens[5].toLong() else 0L
            val irq = if (tokens.size > 6) tokens[6].toLong() else 0L
            val softirq = if (tokens.size > 7) tokens[7].toLong() else 0L
            val steal = if (tokens.size > 8) tokens[8].toLong() else 0L

            val work = user + nice + system + irq + softirq + steal
            val total = work + idle + iowait

            val deltaTotal = total - prevTotalJiffies
            val deltaWork = work - prevWorkJiffies

            prevTotalJiffies = total
            prevWorkJiffies = work

            if (deltaTotal <= 0) return -1.0
            val usage = (deltaWork.toDouble() / deltaTotal.toDouble()) * 100.0
            usage.coerceIn(0.0, 100.0)
        } catch (_: Exception) {
            calculateLoadAvgUsage()
        }
    }

    private fun calculateLoadAvgUsage(): Double {
        return try {
            val loadAvgFile = File("/proc/loadavg")
            if (!loadAvgFile.canRead()) return -1.0
            val content = loadAvgFile.readText().trim()
            val parts = content.split("\\s+".toRegex())
            val oneMinLoad = parts[0].toDouble()
            val cores = max(1, Runtime.getRuntime().availableProcessors())
            val usage = (oneMinLoad / cores) * 100.0
            usage.coerceIn(0.0, 100.0)
        } catch (_: Exception) {
            -1.0
        }
    }

    private fun getNetworkSpeedMetrics(): Map<String, Double> {
        val curRx = TrafficStats.getTotalRxBytes()
        val curTx = TrafficStats.getTotalTxBytes()
        val curTime = System.currentTimeMillis()

        if (prevRxBytes == -1L || prevNetTimestamp == -1L) {
            prevRxBytes = curRx
            prevTxBytes = curTx
            prevNetTimestamp = curTime
            return mapOf("downSpeed" to 0.0, "upSpeed" to 0.0)
        }

        val deltaSec = (curTime - prevNetTimestamp) / 1000.0
        if (deltaSec <= 0.1) {
            return mapOf("downSpeed" to prevSmoothedDown, "upSpeed" to prevSmoothedUp)
        }

        val deltaRx = if (curRx >= prevRxBytes) (curRx - prevRxBytes) else 0L
        val deltaTx = if (curTx >= prevTxBytes) (curTx - prevTxBytes) else 0L

        prevRxBytes = curRx
        prevTxBytes = curTx
        prevNetTimestamp = curTime

        val instantDown = deltaRx.toDouble() / deltaSec
        val instantUp = deltaTx.toDouble() / deltaSec

        val alpha = 0.40
        prevSmoothedDown = if (prevSmoothedDown == 0.0) instantDown else (alpha * instantDown) + ((1.0 - alpha) * prevSmoothedDown)
        prevSmoothedUp = if (prevSmoothedUp == 0.0) instantUp else (alpha * instantUp) + ((1.0 - alpha) * prevSmoothedUp)

        return mapOf(
            "downSpeed" to prevSmoothedDown,
            "upSpeed" to prevSmoothedUp
        )
    }

    private fun getMemoryInfoList(): List<Int> {
        return try {
            val actManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val memInfo = ActivityManager.MemoryInfo()
            actManager.getMemoryInfo(memInfo)
            val totalMb = (memInfo.totalMem / (1024 * 1024)).toInt()
            val availMb = (memInfo.availMem / (1024 * 1024)).toInt()
            listOf(totalMb, availMb)
        } catch (_: Exception) {
            listOf(0, 0)
        }
    }

    private fun getCPUArch(info: String): String {
        return when {
            // --- Common ARM Cores ---
            info.contains("0xd44", ignoreCase = true) -> "Cortex-X1 ARMv8.2-A"
            info.contains("0xd82", ignoreCase = true) -> "Cortex-X4 ARMv9.2-A"
            info.contains("0xd84", ignoreCase = true) -> "Cortex-A725 ARMv9.2-A"
            info.contains("0xd85", ignoreCase = true) -> "Cortex-X925 ARMv9.4-A"
            info.contains("0xc05", ignoreCase = true) -> "Cortex-A5 ARMv7-A"
            info.contains("0xc07", ignoreCase = true) -> "Cortex-A7 ARMv7-A"
            info.contains("0xc08", ignoreCase = true) -> "Cortex-A8 ARMv7-A"
            info.contains("0xc09", ignoreCase = true) -> "Cortex-A9 ARMv7-A"
            info.contains("0xc0d", ignoreCase = true) -> "Cortex-A12 ARMv7-A"
            info.contains("0xc0e", ignoreCase = true) -> "Cortex-A17 ARMv7-A"
            info.contains("0xc0f", ignoreCase = true) -> "Cortex-A15 ARMv7-A"
            info.contains("0xd01", ignoreCase = true) -> "Cortex-A32 ARMv8-A (32-bit)"
            info.contains("0xd02", ignoreCase = true) -> "Cortex-A34 ARMv8-A"
            info.contains("0xd03", ignoreCase = true) -> "Cortex-A53 ARMv8-A"
            info.contains("0xd04", ignoreCase = true) -> "Cortex-A35 ARMv8-A"
            info.contains("0xd05", ignoreCase = true) -> "Cortex-A55 ARMv8.2-A"
            info.contains("0xd06", ignoreCase = true) -> "Cortex-A65 ARMv8.2-A"
            info.contains("0xd07", ignoreCase = true) -> "Cortex-A57 ARMv8-A"
            info.contains("0xd08", ignoreCase = true) -> "Cortex-A72 ARMv8-A"
            info.contains("0xd09", ignoreCase = true) -> "Cortex-A73 ARMv8-A"
            info.contains("0xd0a", ignoreCase = true) -> "Cortex-A75 ARMv8.2-A"
            info.contains("0xd0b", ignoreCase = true) -> "Cortex-A76 ARMv8.2-A"
            info.contains("0xd0d", ignoreCase = true) -> "Cortex-A77 ARMv8.2-A"
            info.contains("0xd0e", ignoreCase = true) -> "Cortex-A76AE ARMv8.2-A"
            info.contains("0xd41", ignoreCase = true) -> "Cortex-A78 ARMv8.2-A"
            info.contains("0xd43", ignoreCase = true) -> "Cortex-A65AE ARMv8.2-A"
            info.contains("0xd46", ignoreCase = true) -> "Cortex-A510 ARMv9-A"
            info.contains("0xd47", ignoreCase = true) -> "Cortex-A710 ARMv9-A"
            info.contains("0xd48", ignoreCase = true) -> "Cortex-X2 ARMv9-A"
            info.contains("0xd4d", ignoreCase = true) -> "Cortex-A715 ARMv9.2-A"
            info.contains("0xd4e", ignoreCase = true) -> "Cortex-X3 ARMv9-A"

            // --- Qualcomm Oryon V2 (Snapdragon 8 Gen 5 etc.) ---
            info.contains("0x002", ignoreCase = true) -> {
                when {
                    info.contains("0x3", ignoreCase = true) -> "Qualcomm Oryon V2 (Performance)"
                    info.contains("0x2", ignoreCase = true) -> "Qualcomm Oryon V2 (Efficiency)"
                    else -> "Qualcomm Oryon V2"
                }
            }

            // --- Qualcomm Oryon V1 (Snapdragon 8 Elite / 8 Gen 4) ---
            info.contains("0x001", ignoreCase = true) -> {
                val parts = info.split(";").map { it.trim() }
                when {
                    parts.contains("0x2") || parts.contains("0x3") -> "Qualcomm Oryon V1 (Performance)"
                    parts.contains("0x4") || parts.contains("0x5") -> "Qualcomm Oryon V1 (Efficiency)"
                    else -> "Qualcomm Oryon V1"
                }
            }

            // --- Fallback handling ---
            info.contains("kB", ignoreCase = true) -> Regex("\\d+").find(info)?.value ?: info
            else -> info.trim().ifEmpty { "ARMv8/v9 Architecture" }
        }
    }

    private fun getHardwareData(): Map<String, Any> {
        val data = mutableMapOf<String, Any>()

        // Read CPU part / implementer info from /proc/cpuinfo per core
        val cpuPartMap = mutableMapOf<Int, String>()
        try {
            val lines = File("/proc/cpuinfo").readLines()
            var currentProcessor = -1
            for (line in lines) {
                val trimmed = line.trim()
                if (trimmed.startsWith("processor", ignoreCase = true)) {
                    val parts = trimmed.split(":")
                    if (parts.size >= 2) {
                        currentProcessor = parts[1].trim().toIntOrNull() ?: -1
                    }
                } else if (trimmed.startsWith("CPU part", ignoreCase = true) && currentProcessor >= 0) {
                    val parts = trimmed.split(":")
                    if (parts.size >= 2) {
                        val partHex = parts[1].trim()
                        cpuPartMap[currentProcessor] = partHex
                    }
                }
            }
        } catch (_: Exception) {}

        val coreList = mutableListOf<Map<String, String>>()
        val cpuDir = File("/sys/devices/system/cpu/")
        val cpuFiles = cpuDir.listFiles { file -> file.name.matches("cpu\\d+".toRegex()) }

        cpuFiles?.sortedBy { it.name }?.forEach { dir ->
            val coreId = dir.name.replace("cpu", "")
            val coreIndex = coreId.toIntOrNull() ?: -1
            val maxFreq = try { File("${dir.path}/cpufreq/cpuinfo_max_freq").readText().trim().toLong() / 1000 } catch (_: Exception) { 0L }
            val curFreq = try {
                val f1 = File("${dir.path}/cpufreq/scaling_cur_freq")
                val text = if (f1.exists() && f1.canRead()) {
                    f1.readText().trim()
                } else {
                    File("${dir.path}/cpufreq/cpuinfo_cur_freq").readText().trim()
                }
                text.toLong() / 1000
            } catch (_: Exception) { 0L }

            val rawPart = cpuPartMap[coreIndex] ?: ""
            val archName = getCPUArch(rawPart)

            coreList.add(mapOf(
                "id" to "Core $coreId",
                "freq" to "$curFreq MHz / $maxFreq MHz",
                "curFreqMhz" to "$curFreq",
                "maxFreqMhz" to "$maxFreq",
                "arch" to archName
            ))
        }
        data["cores"] = coreList

        val memInfo = try {
            File("/proc/meminfo").readLines().find { it.startsWith("MemTotal") }?.split(":")?.get(1)?.trim() ?: "Unknown"
        } catch (_: Exception) { "Unknown" }
        data["memory"] = memInfo

        return data
    }
}
