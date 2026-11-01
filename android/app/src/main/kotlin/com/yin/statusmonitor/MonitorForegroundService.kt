package com.yin.statusmonitor

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.Icon
import android.net.TrafficStats
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
import android.widget.LinearLayout
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

class MonitorForegroundService : Service() {

    companion object {
        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"

        const val EXTRA_STATUSBAR_ENABLED = "EXTRA_STATUSBAR_ENABLED"
        const val EXTRA_MODE = "EXTRA_MODE"
        const val EXTRA_CPU_METRIC = "EXTRA_CPU_METRIC"
        const val EXTRA_INTERVAL = "EXTRA_INTERVAL"
        const val EXTRA_CPU_ENABLED = "EXTRA_CPU_ENABLED"
        const val EXTRA_MEM_ENABLED = "EXTRA_MEM_ENABLED"
        const val EXTRA_NET_ENABLED = "EXTRA_NET_ENABLED"
        const val EXTRA_FLOATING_ENABLED = "EXTRA_FLOATING_ENABLED"
        const val EXTRA_FLOATING_MODE = "EXTRA_FLOATING_MODE"
        const val EXTRA_FLOATING_SCALE = "EXTRA_FLOATING_SCALE"
        const val EXTRA_FLOATING_OPACITY = "EXTRA_FLOATING_OPACITY"
        const val EXTRA_FLOATING_TAP_ENABLED = "EXTRA_FLOATING_TAP_ENABLED"

        const val CHANNEL_USAGE = "status_monitor_usage_channel"
        const val CHANNEL_SPEED = "status_monitor_speed_channel"
        const val NOTIF_ID_USAGE = 1001
        const val NOTIF_ID_SPEED = 1002

        private const val PREFS_FLOATING = "floating_window_prefs"
        private const val KEY_FLOATING_X = "floating_pos_x"
        private const val KEY_FLOATING_Y = "floating_pos_y"

        // Latest telemetry accessible to Flutter Activity
        var latestCpuTime: Double = 0.0
        var latestCpuFreq: Double = 0.0
        var latestDownSpeed: Double = 0.0
        var latestUpSpeed: Double = 0.0
        var latestUsedMemGb: Double = 0.0
        var latestTotalMemGb: Double = 8.0

        fun startOrUpdate(
            context: Context,
            statusBarEnabled: Boolean,
            mode: String,
            cpuMetric: String,
            intervalMs: Long,
            cpuEnabled: Boolean = true,
            memEnabled: Boolean = true,
            netEnabled: Boolean = true,
            floatingEnabled: Boolean = false,
            floatingMode: String = "usage",
            floatingScale: Double = 0.10,
            floatingOpacity: Double = 0.80,
            floatingTapEnabled: Boolean = false
        ) {
            val serviceActive = statusBarEnabled || floatingEnabled
            val intent = Intent(context, MonitorForegroundService::class.java).apply {
                if (serviceActive) {
                    action = ACTION_START
                    putExtra(EXTRA_STATUSBAR_ENABLED, statusBarEnabled)
                    putExtra(EXTRA_MODE, mode)
                    putExtra(EXTRA_CPU_METRIC, cpuMetric)
                    putExtra(EXTRA_INTERVAL, intervalMs)
                    putExtra(EXTRA_CPU_ENABLED, cpuEnabled)
                    putExtra(EXTRA_MEM_ENABLED, memEnabled)
                    putExtra(EXTRA_NET_ENABLED, netEnabled)
                    putExtra(EXTRA_FLOATING_ENABLED, floatingEnabled)
                    putExtra(EXTRA_FLOATING_MODE, floatingMode)
                    putExtra(EXTRA_FLOATING_SCALE, floatingScale)
                    putExtra(EXTRA_FLOATING_OPACITY, floatingOpacity)
                    putExtra(EXTRA_FLOATING_TAP_ENABLED, floatingTapEnabled)
                } else {
                    action = ACTION_STOP
                }
            }
            if (serviceActive) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } else {
                context.stopService(intent)
            }
        }
    }

    private val serviceStartTime = System.currentTimeMillis()

    // Bitmap and text cache to prevent unnecessary notification layout re-renders
    private var lastUsageCpuText = ""
    private var lastUsageMemText = ""
    private var lastUsageBitmap: Bitmap? = null

    private var lastSpeedValText = ""
    private var lastSpeedUnitText = ""
    private var lastSpeedBitmap: Bitmap? = null

    private val handler = Handler(Looper.getMainLooper())
    private var isRunning = false
    private var isScreenOn = true
    private var screenReceiver: BroadcastReceiver? = null
    private var isForegroundStarted = false
    private var currentForegroundNotifId = 0
    private var isStatusBarEnabled = true
    private var currentMode = "usage" // "usage", "speed", "both"
    private var currentCpuMetric = "time" // "time", "freq"
    private var isCpuMonEnabled = true
    private var isMemMonEnabled = true
    private var isNetMonEnabled = true
    private var samplingInterval = 1000L

    // Floating window state
    private var isFloatingEnabled = false
    private var currentFloatingMode = "usage" // "usage", "speed", "both"
    private var currentFloatingScale = 0.10 // 5% to 15% of screen width
    private var currentFloatingOpacity = 0.80
    private var isFloatingTapEnabled = false
    private var windowManager: WindowManager? = null
    private var floatingRootView: View? = null
    private var floatingUsageImageView: ImageView? = null
    private var floatingSpeedImageView: ImageView? = null
    private var floatingLayoutParams: WindowManager.LayoutParams? = null
    private var floatingX = -1
    private var floatingY = -1

    private fun loadFloatingPosition() {
        if (floatingX == -1 || floatingY == -1) {
            val prefs = getSharedPreferences(PREFS_FLOATING, Context.MODE_PRIVATE)
            floatingX = prefs.getInt(KEY_FLOATING_X, 80)
            floatingY = prefs.getInt(KEY_FLOATING_Y, 200)
        }
    }

    private fun saveFloatingPosition(x: Int, y: Int) {
        val prefs = getSharedPreferences(PREFS_FLOATING, Context.MODE_PRIVATE)
        prefs.edit()
            .putInt(KEY_FLOATING_X, x)
            .putInt(KEY_FLOATING_Y, y)
            .apply()
    }

    // CPU telemetry tracking
    private var coreCount = max(1, Runtime.getRuntime().availableProcessors())
    private var prevCpuTimes: Array<Array<Long>>? = null
    private var lastCpuUsage = Array(coreCount) { intArrayOf(0, 0) }

    // Network telemetry tracking
    private var prevRxBytes = -1L
    private var prevTxBytes = -1L
    private var prevNetTimestamp = -1L
    private var prevSmoothedDown = 0.0
    private var prevSmoothedUp = 0.0

    private val tickerRunnable = object : Runnable {
        override fun run() {
            if (isRunning && isScreenOn) {
                sampleAndNotify()
                handler.postDelayed(this, samplingInterval)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
        isScreenOn = pm?.isInteractive ?: true
        initChannels()
        registerScreenReceiver()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START

        if (action == ACTION_STOP) {
            stopMonitoring()
            return START_NOT_STICKY
        }

        registerScreenReceiver()

        isStatusBarEnabled = intent?.getBooleanExtra(EXTRA_STATUSBAR_ENABLED, isStatusBarEnabled) ?: isStatusBarEnabled
        currentMode = intent?.getStringExtra(EXTRA_MODE) ?: currentMode
        currentCpuMetric = intent?.getStringExtra(EXTRA_CPU_METRIC) ?: currentCpuMetric
        val newInterval = intent?.getLongExtra(EXTRA_INTERVAL, samplingInterval)?.coerceIn(500L, 5000L) ?: samplingInterval
        val intervalChanged = (newInterval != samplingInterval)
        samplingInterval = newInterval

        isCpuMonEnabled = intent?.getBooleanExtra(EXTRA_CPU_ENABLED, isCpuMonEnabled) ?: isCpuMonEnabled
        isMemMonEnabled = intent?.getBooleanExtra(EXTRA_MEM_ENABLED, isMemMonEnabled) ?: isMemMonEnabled
        isNetMonEnabled = intent?.getBooleanExtra(EXTRA_NET_ENABLED, isNetMonEnabled) ?: isNetMonEnabled

        val newFloatingEnabled = intent?.getBooleanExtra(EXTRA_FLOATING_ENABLED, isFloatingEnabled) ?: isFloatingEnabled
        val newFloatingMode = intent?.getStringExtra(EXTRA_FLOATING_MODE) ?: currentFloatingMode
        val newFloatingScale = intent?.getDoubleExtra(EXTRA_FLOATING_SCALE, currentFloatingScale)?.coerceIn(0.04, 0.25) ?: currentFloatingScale
        val newFloatingOpacity = intent?.getDoubleExtra(EXTRA_FLOATING_OPACITY, currentFloatingOpacity)?.coerceIn(0.2, 1.0) ?: currentFloatingOpacity
        val newFloatingTapEnabled = intent?.getBooleanExtra(EXTRA_FLOATING_TAP_ENABLED, isFloatingTapEnabled) ?: isFloatingTapEnabled

        val floatingConfigChanged = (newFloatingEnabled != isFloatingEnabled ||
                newFloatingMode != currentFloatingMode ||
                newFloatingScale != currentFloatingScale ||
                newFloatingOpacity != currentFloatingOpacity ||
                newFloatingTapEnabled != isFloatingTapEnabled)

        isFloatingEnabled = newFloatingEnabled
        currentFloatingMode = newFloatingMode
        currentFloatingScale = newFloatingScale
        currentFloatingOpacity = newFloatingOpacity
        isFloatingTapEnabled = newFloatingTapEnabled

        if (floatingConfigChanged) {
            removeFloatingWindow()
        }

        if (!isStatusBarEnabled && !isFloatingEnabled) {
            stopMonitoring()
            return START_NOT_STICKY
        }

        val targetNotifId = if (currentMode == "speed") NOTIF_ID_SPEED else NOTIF_ID_USAGE
        val needStartForeground = !isForegroundStarted || (currentForegroundNotifId != targetNotifId)

        if (needStartForeground) {
            val initialNotif = if (isStatusBarEnabled) {
                buildCurrentForegroundNotification()
            } else {
                buildServiceNotification()
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(targetNotifId, initialNotif, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(targetNotifId, initialNotif)
            }
            isForegroundStarted = true
            currentForegroundNotifId = targetNotifId
        }

        // Only sample and schedule ticks when the screen is active
        if (isScreenOn) {
            sampleAndNotify()
        }

        if (!isRunning) {
            isRunning = true
            if (isScreenOn) {
                handler.post(tickerRunnable)
            }
        } else if (intervalChanged && isScreenOn) {
            handler.removeCallbacks(tickerRunnable)
            handler.postDelayed(tickerRunnable, samplingInterval)
        }

        return START_STICKY
    }

    private fun registerScreenReceiver() {
        if (screenReceiver != null) return
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_SCREEN_OFF -> {
                        isScreenOn = false
                        handler.removeCallbacks(tickerRunnable)
                    }
                    Intent.ACTION_SCREEN_ON, Intent.ACTION_USER_PRESENT -> {
                        if (!isScreenOn) {
                            isScreenOn = true
                            if (isRunning) {
                                // Reset baselines to prevent skewed metrics over the sleep period
                                prevCpuTimes = null
                                prevRxBytes = -1L
                                prevTxBytes = -1L
                                prevNetTimestamp = -1L
                                prevSmoothedDown = 0.0
                                prevSmoothedUp = 0.0

                                handler.removeCallbacks(tickerRunnable)
                                handler.post(tickerRunnable)
                            }
                        }
                    }
                }
            }
        }
        screenReceiver = receiver
        registerReceiver(receiver, filter)
    }

    private fun unregisterScreenReceiver() {
        screenReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
            screenReceiver = null
        }
    }

    private fun stopMonitoring() {
        isRunning = false
        isForegroundStarted = false
        currentForegroundNotifId = 0
        handler.removeCallbacks(tickerRunnable)
        removeFloatingWindow()
        unregisterScreenReceiver()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(NOTIF_ID_USAGE)
        nm.cancel(NOTIF_ID_SPEED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        unregisterScreenReceiver()
        stopMonitoring()
        super.onDestroy()
    }

    private fun initChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            val usageChannel = NotificationChannel(
                CHANNEL_USAGE,
                "Resource Usage Monitor",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Live CPU and RAM status bar icon"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            nm.createNotificationChannel(usageChannel)

            val speedChannel = NotificationChannel(
                CHANNEL_SPEED,
                "Network Speed Monitor",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Live Network speed status bar icon"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            nm.createNotificationChannel(speedChannel)

            // Clean up deprecated service channel if it existed from previous versions
            try {
                nm.deleteNotificationChannel("status_monitor_service_channel")
            } catch (_: Exception) {}
        }
    }

    private fun buildServiceNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_USAGE)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder.apply {
            setSmallIcon(android.R.drawable.stat_notify_sync)
            setContentTitle("Status Monitor")
            setContentText("Background telemetry active")
            setOngoing(true)
            setOnlyAlertOnce(true)
            setShowWhen(false)
            setCategory(Notification.CATEGORY_SERVICE)
        }.build()
    }

    private fun buildCurrentForegroundNotification(): Notification {
        return if (currentMode == "speed") {
            buildSpeedNotification()
        } else {
            buildUsageNotification()
        }
    }

    private fun buildUsageNotification(): Notification {
        val activeCpu = if (currentCpuMetric == "time") latestCpuTime else latestCpuFreq
        val cpuLabel = "CPU"
        val usageIconBitmap = createUsageIconBitmap(activeCpu, latestUsedMemGb)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_USAGE)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val cpuPart = if (isCpuMonEnabled) "$cpuLabel: ${activeCpu.roundToInt().coerceIn(0, 100)}%" else "CPU: Off"
        val memPart = if (isMemMonEnabled) "RAM: ${String.format("%.1f", latestUsedMemGb)} / ${String.format("%.1f", latestTotalMemGb)} GB" else "RAM: Off"

        return builder.apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                setSmallIcon(Icon.createWithBitmap(usageIconBitmap))
            } else {
                setSmallIcon(android.R.drawable.stat_notify_sync)
            }
            setContentTitle("Resource Usage")
            setContentText("$cpuPart | $memPart")
            setOngoing(true)
            setOnlyAlertOnce(true)
            setWhen(serviceStartTime + 1000L) // Stable timestamp ensures deterministic position
            setShowWhen(false)
            setLocalOnly(true)
            setVisibility(Notification.VISIBILITY_PUBLIC)
            setCategory(Notification.CATEGORY_STATUS)
        }.build()
    }

    private fun buildSpeedNotification(): Notification {
        val (speedVal, speedUnit) = formatSpeedComponents(latestDownSpeed)
        val (upVal, upUnit) = formatSpeedComponents(latestUpSpeed)
        val speedIconBitmap = createSpeedIconBitmap(latestDownSpeed)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_SPEED)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder.apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                setSmallIcon(Icon.createWithBitmap(speedIconBitmap))
            } else {
                setSmallIcon(android.R.drawable.stat_sys_download)
            }
            setContentTitle("Network Speed")
            setContentText("↓ $speedVal $speedUnit | ↑ $upVal $upUnit")
            setOngoing(true)
            setOnlyAlertOnce(true)
            setWhen(serviceStartTime) // Consistently after usage notification
            setShowWhen(false)
            setLocalOnly(true)
            setVisibility(Notification.VISIBILITY_PUBLIC)
            setCategory(Notification.CATEGORY_STATUS)
        }.build()
    }

    // Main periodic sampling executed continuously in the foreground background service
    private fun sampleAndNotify() {
        if (isCpuMonEnabled) {
            val (cpuTime, cpuFreq) = computeCpuUsage()
            latestCpuTime = cpuTime
            latestCpuFreq = cpuFreq
        } else {
            latestCpuTime = 0.0
            latestCpuFreq = 0.0
        }

        if (isMemMonEnabled) {
            val (usedGb, totalGb) = computeMemoryUsage()
            latestUsedMemGb = usedGb
            latestTotalMemGb = totalGb
        } else {
            latestUsedMemGb = 0.0
        }

        if (isNetMonEnabled) {
            val (downSpeed, upSpeed) = computeNetworkSpeed()
            latestDownSpeed = downSpeed
            latestUpSpeed = upSpeed
        } else {
            latestDownSpeed = 0.0
            latestUpSpeed = 0.0
        }

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (isStatusBarEnabled) {
            val showUsage = currentMode == "usage" || currentMode == "both"
            val showSpeed = currentMode == "speed" || currentMode == "both"

            if (showUsage) {
                nm.notify(NOTIF_ID_USAGE, buildUsageNotification())
            } else {
                nm.cancel(NOTIF_ID_USAGE)
            }

            if (showSpeed) {
                nm.notify(NOTIF_ID_SPEED, buildSpeedNotification())
            } else {
                nm.cancel(NOTIF_ID_SPEED)
            }
        } else {
            nm.cancel(NOTIF_ID_SPEED)
            nm.notify(NOTIF_ID_USAGE, buildServiceNotification())
        }

        updateFloatingWindow()
    }

    // Exact Dual-Stage CPU calculation
    private fun computeCpuUsage(): Pair<Double, Double> {
        val detectedCores = getCoreCount()
        if (lastCpuUsage.size != detectedCores) {
            coreCount = detectedCores
            lastCpuUsage = Array(coreCount) { intArrayOf(0, 0) }
            prevCpuTimes = null
        }

        val currentCpuTimes = Array(coreCount) { i -> readCpuStatus(i) }
        val prev = prevCpuTimes
        if (prev == null || prev.size != coreCount) {
            prevCpuTimes = currentCpuTimes
            return Pair(latestCpuTime, latestCpuFreq)
        }
        prevCpuTimes = currentCpuTimes

        val maxFreqs = LongArray(coreCount) { i ->
            readFirstLine("/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq").toLongOrNull() ?: 1L
        }
        val sumMaxFreq = max(1L, maxFreqs.sum())

        var hasValidData = false
        for (i in 0 until coreCount) {
            val timeDelta = currentCpuTimes[i][2] - prev[i][2]
            if (timeDelta > 0) {
                val rawUsage1 = (currentCpuTimes[i][1] - prev[i][1]) * 100L / timeDelta
                val rawUsage2 = 100L - (currentCpuTimes[i][0] - prev[i][0]) * 100L / timeDelta

                lastCpuUsage[i][0] = rawUsage1.coerceIn(0L, 100L).toInt()
                lastCpuUsage[i][1] = rawUsage2.coerceIn(0L, 100L).toInt()
                hasValidData = true
            }
        }

        if (hasValidData) {
            var totalWeightedWork = 0.0
            for (i in 0 until coreCount) {
                totalWeightedWork += lastCpuUsage[i][0].toDouble() * maxFreqs[i].toDouble()
            }
            val avgWork = (totalWeightedWork / sumMaxFreq.toDouble()).coerceIn(0.0, 100.0)
            val avgIdle = lastCpuUsage.map { it[1] }.average().coerceIn(0.0, 100.0)
            return Pair(avgIdle, avgWork)
        }

        return Pair(latestCpuTime, latestCpuFreq)
    }

    private fun readCpuStatus(cpuIndex: Int): Array<Long> {
        val root = "/sys/devices/system/cpu/cpu$cpuIndex"
        val alltimePath = "$root/cpufreq/stats/time_in_state"
        val maxFreqPath = "$root/cpufreq/cpuinfo_max_freq"

        return try {
            val maxFreq = readFirstLine(maxFreqPath).toLongOrNull() ?: 1L
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

    private fun computeMemoryUsage(): Pair<Double, Double> {
        return try {
            val actManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val memInfo = ActivityManager.MemoryInfo()
            actManager.getMemoryInfo(memInfo)
            val totalGb = memInfo.totalMem.toDouble() / (1024.0 * 1024.0 * 1024.0)
            val usedGb = (memInfo.totalMem - memInfo.availMem).toDouble() / (1024.0 * 1024.0 * 1024.0)
            Pair(usedGb, totalGb)
        } catch (_: Exception) {
            Pair(0.0, 8.0)
        }
    }

    private fun computeNetworkSpeed(): Pair<Double, Double> {
        val curRx = TrafficStats.getTotalRxBytes()
        val curTx = TrafficStats.getTotalTxBytes()
        val curTime = System.currentTimeMillis()

        if (prevRxBytes == -1L || prevNetTimestamp == -1L) {
            prevRxBytes = curRx
            prevTxBytes = curTx
            prevNetTimestamp = curTime
            return Pair(0.0, 0.0)
        }

        val deltaSec = (curTime - prevNetTimestamp) / 1000.0
        if (deltaSec <= 0.1) {
            return Pair(prevSmoothedDown, prevSmoothedUp)
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

        return Pair(prevSmoothedDown, prevSmoothedUp)
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

    // Path transform based text rasterization to fill 100% of the canvas bounding box
    fun createBitmapFromString(stateValue: Array<String>, size: Float, px: Int = 96, refText: String? = null): Bitmap {
        val bitmap = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            typeface = Typeface.create("sans-serif-condensed", Typeface.BOLD)
            textSize = 100f // Reference font size for path generation
        }
        val gap = px * 0.06f                 // Tight vertical gap between lines
        val h1 = (px - gap) * size           // Height allocated to first line

        drawFitted(canvas, paint, stateValue[0], RectF(0f, 0f, px.toFloat(), h1), refText = refText)
        drawFitted(canvas, paint, stateValue[1], RectF(0f, h1 + gap, px.toFloat(), px.toFloat()))
        return bitmap
    }

    /** Scales and translates text glyph path to fill target bounding box with optional horizontal stretch */
    private fun drawFitted(canvas: Canvas, paint: Paint, text: String, dst: RectF, refText: String? = null, maxStretch: Float = 1.35f) {
        if (text.isEmpty()) return
        val measureText = refText ?: text
        val refPath = Path()
        paint.getTextPath(measureText, 0, measureText.length, 0f, 0f, refPath)
        val refB = RectF().also { refPath.computeBounds(it, true) }

        val path = Path()
        paint.getTextPath(text, 0, text.length, 0f, 0f, path)
        val b = RectF().also { path.computeBounds(it, true) }
        if (refB.width() <= 0f || refB.height() <= 0f || b.height() <= 0f) return

        val sy = dst.height() / refB.height()
        val sx = minOf(dst.width() / refB.width(), sy * maxStretch)
        val m = Matrix().apply {
            postTranslate(-b.left, -b.top)
            postScale(sx, sy)
            postTranslate(dst.left + (dst.width() - b.width() * sx) / 2f, dst.top)
        }
        path.transform(m)
        canvas.drawPath(path, paint)
    }

    private fun createUsageIconBitmap(cpuPercent: Double, usedMemGb: Double): Bitmap {
        val cpuText = if (isCpuMonEnabled) "${cpuPercent.roundToInt().coerceIn(0, 100)}%" else "--"
        val memText = if (isMemMonEnabled) "${String.format("%.1f", usedMemGb)}G" else "--"
        val cached = lastUsageBitmap
        if (cached != null && cpuText == lastUsageCpuText && memText == lastUsageMemText) {
            return cached
        }
        lastUsageCpuText = cpuText
        lastUsageMemText = memText
        val bmp = createBitmapFromString(arrayOf(cpuText, memText), size = 0.60f, px = 96, refText = "100%")
        lastUsageBitmap = bmp
        return bmp
    }

    private fun createSpeedIconBitmap(downSpeedBytes: Double): Bitmap {
        val (speedVal, speedUnit) = if (isNetMonEnabled) {
            formatSpeedComponents(downSpeedBytes)
        } else {
            Pair("--", "KB/s")
        }
        val cached = lastSpeedBitmap
        if (cached != null && speedVal == lastSpeedValText && speedUnit == lastSpeedUnitText) {
            return cached
        }
        lastSpeedValText = speedVal
        lastSpeedUnitText = speedUnit
        val bmp = createBitmapFromString(arrayOf(speedVal, speedUnit), size = 0.60f, px = 96, refText = "99.9")
        lastSpeedBitmap = bmp
        return bmp
    }

    private fun formatSpeedComponents(bytesPerSec: Double): Pair<String, String> {
        val kb = bytesPerSec / 1024.0
        return when {
            kb >= 1024.0 -> {
                val mb = kb / 1024.0
                Pair(if (mb >= 10) String.format("%.0f", mb) else String.format("%.1f", mb), "MB/s")
            }
            kb >= 1.0 -> {
                Pair(String.format("%.0f", kb), "KB/s")
            }
            else -> {
                Pair("0", "KB/s")
            }
        }
    }

    // --- Floating Window Implementation ---
    private fun updateFloatingWindow() {
        if (!isFloatingEnabled) {
            removeFloatingWindow()
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            removeFloatingWindow()
            return
        }

        if (windowManager == null) {
            windowManager = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        }
        val wm = windowManager ?: return

        if (floatingRootView == null) {
            buildFloatingView(wm)
        }

        val activeCpu = if (currentCpuMetric == "time") latestCpuTime else latestCpuFreq
        val displayMetrics = resources.displayMetrics
        val screenWidth = minOf(displayMetrics.widthPixels, displayMetrics.heightPixels)
        val cardPx = (screenWidth * currentFloatingScale).toInt().coerceAtLeast(32)
        val renderPx = max(96, cardPx)

        if (currentFloatingMode == "usage" || currentFloatingMode == "both") {
            val usageBmp = createFloatingUsageBitmap(activeCpu, latestUsedMemGb, renderPx)
            floatingUsageImageView?.setImageBitmap(usageBmp)
        }

        if (currentFloatingMode == "speed" || currentFloatingMode == "both") {
            val speedBmp = createFloatingSpeedBitmap(latestDownSpeed, renderPx)
            floatingSpeedImageView?.setImageBitmap(speedBmp)
        }
    }

    private fun getScreenDimensions(wm: WindowManager): Pair<Int, Int> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val metrics = wm.currentWindowMetrics
            val bounds = metrics.bounds
            Pair(bounds.width(), bounds.height())
        } else {
            val dm = resources.displayMetrics
            Pair(dm.widthPixels, dm.heightPixels)
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        windowManager?.let { wm ->
            if (isFloatingEnabled && floatingRootView != null) {
                buildFloatingView(wm)
            }
        }
    }

    private fun buildFloatingView(wm: WindowManager) {
        removeFloatingWindow()

        val displayMetrics = resources.displayMetrics
        val screenWidth = minOf(displayMetrics.widthPixels, displayMetrics.heightPixels)
        val cardPx = (screenWidth * currentFloatingScale).toInt().coerceAtLeast(32)
        val density = displayMetrics.density
        val radiusPx = cardPx * 0.22f
        val paddingPx = (cardPx * 0.10f).toInt()
        val alphaInt = (currentFloatingOpacity * 255).toInt().coerceIn(30, 255)

        val rootLayout = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }

        fun createCard(): Pair<LinearLayout, ImageView> {
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                val bg = GradientDrawable().apply {
                    shape = GradientDrawable.RECTANGLE
                    cornerRadius = radiusPx
                    setColor(Color.argb(alphaInt, 18, 22, 30))
                    setStroke((1 * density).toInt().coerceAtLeast(1), Color.argb(70, 255, 255, 255))
                }
                background = bg
                setPadding(paddingPx, paddingPx, paddingPx, paddingPx)
            }
            val iv = ImageView(this).apply {
                scaleType = ImageView.ScaleType.FIT_CENTER
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.MATCH_PARENT
                )
            }
            card.addView(iv)
            return Pair(card, iv)
        }

        val showUsage = currentFloatingMode == "usage" || currentFloatingMode == "both"
        val showSpeed = currentFloatingMode == "speed" || currentFloatingMode == "both"

        if (showUsage) {
            val (usageCard, usageIv) = createCard()
            floatingUsageImageView = usageIv
            val cardLp = LinearLayout.LayoutParams(cardPx, cardPx)
            if (showSpeed) {
                cardLp.rightMargin = (8 * density).toInt()
            }
            rootLayout.addView(usageCard, cardLp)
        }

        if (showSpeed) {
            val (speedCard, speedIv) = createCard()
            floatingSpeedImageView = speedIv
            val cardLp = LinearLayout.LayoutParams(cardPx, cardPx)
            rootLayout.addView(speedCard, cardLp)
        }

        // Bounded positioning ensuring window stays 100% within screen limits
        loadFloatingPosition()
        val (screenW, screenH) = getScreenDimensions(wm)
        val initialViewWidth = if (showUsage && showSpeed) cardPx * 2 + (8 * density).toInt() else cardPx
        val initialViewHeight = cardPx
        val initialMaxX = (screenW - initialViewWidth).coerceAtLeast(0)
        val initialMaxY = (screenH - initialViewHeight).coerceAtLeast(0)
        floatingX = floatingX.coerceIn(0, initialMaxX)
        floatingY = floatingY.coerceIn(0, initialMaxY)
        saveFloatingPosition(floatingX, floatingY)

        // Touch listener for smooth bounded dragging and tap-to-open
        var lastTouchX = 0f
        var lastTouchY = 0f
        var downRawX = 0f
        var downRawY = 0f
        var touchStartTime = 0L

        rootLayout.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    lastTouchX = event.rawX
                    lastTouchY = event.rawY
                    downRawX = event.rawX
                    downRawY = event.rawY
                    touchStartTime = System.currentTimeMillis()
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val (curWidth, curHeight) = getScreenDimensions(wm)
                    val viewWidth = if (rootLayout.width > 0) rootLayout.width else initialViewWidth
                    val viewHeight = if (rootLayout.height > 0) rootLayout.height else initialViewHeight

                    val maxX = (curWidth - viewWidth).coerceAtLeast(0)
                    val maxY = (curHeight - viewHeight).coerceAtLeast(0)

                    val dx = (event.rawX - lastTouchX).toInt()
                    val dy = (event.rawY - lastTouchY).toInt()

                    floatingX = (floatingX + dx).coerceIn(0, maxX)
                    floatingY = (floatingY + dy).coerceIn(0, maxY)

                    lastTouchX = event.rawX
                    lastTouchY = event.rawY

                    floatingLayoutParams?.let { lp ->
                        lp.x = floatingX
                        lp.y = floatingY
                        try {
                            wm.updateViewLayout(rootLayout, lp)
                        } catch (_: Exception) {}
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    saveFloatingPosition(floatingX, floatingY)
                    val duration = System.currentTimeMillis() - touchStartTime
                    val dist = Math.hypot((event.rawX - downRawX).toDouble(), (event.rawY - downRawY).toDouble())
                    if (isFloatingTapEnabled && duration < 300 && dist < 12 * density) {
                        try {
                            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                            }
                            if (launchIntent != null) {
                                startActivity(launchIntent)
                            }
                        } catch (_: Exception) {}
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    saveFloatingPosition(floatingX, floatingY)
                    false
                }
                else -> false
            }
        }

        val windowType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val layoutParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = floatingX
            y = floatingY
        }

        floatingLayoutParams = layoutParams
        floatingRootView = rootLayout

        try {
            wm.addView(rootLayout, layoutParams)
        } catch (_: Exception) {
            floatingRootView = null
        }
    }

    private fun removeFloatingWindow() {
        try {
            if (floatingRootView != null && floatingRootView?.isAttachedToWindow == true) {
                windowManager?.removeViewImmediate(floatingRootView)
            }
        } catch (_: Exception) {}
        floatingRootView = null
        floatingUsageImageView = null
        floatingSpeedImageView = null
    }

    private var lastFloatUsageCpuText = ""
    private var lastFloatUsageMemText = ""
    private var lastFloatUsagePx = 0
    private var lastFloatUsageBitmap: Bitmap? = null

    private fun createFloatingUsageBitmap(cpuPercent: Double, usedMemGb: Double, px: Int): Bitmap {
        val cpuText = if (isCpuMonEnabled) "${cpuPercent.roundToInt().coerceIn(0, 100)}%" else "--"
        val memText = if (isMemMonEnabled) "${String.format("%.1f", usedMemGb)}G" else "--"
        val cached = lastFloatUsageBitmap
        if (cached != null && cpuText == lastFloatUsageCpuText && memText == lastFloatUsageMemText && px == lastFloatUsagePx) {
            return cached
        }
        lastFloatUsageCpuText = cpuText
        lastFloatUsageMemText = memText
        lastFloatUsagePx = px
        val bmp = createBitmapFromString(arrayOf(cpuText, memText), size = 0.60f, px = px, refText = "100%")
        lastFloatUsageBitmap = bmp
        return bmp
    }

    private var lastFloatSpeedValText = ""
    private var lastFloatSpeedUnitText = ""
    private var lastFloatSpeedPx = 0
    private var lastFloatSpeedBitmap: Bitmap? = null

    private fun createFloatingSpeedBitmap(downSpeedBytes: Double, px: Int): Bitmap {
        val (speedVal, speedUnit) = if (isNetMonEnabled) {
            formatSpeedComponents(downSpeedBytes)
        } else {
            Pair("--", "KB/s")
        }
        val cached = lastFloatSpeedBitmap
        if (cached != null && speedVal == lastFloatSpeedValText && speedUnit == lastFloatSpeedUnitText && px == lastFloatSpeedPx) {
            return cached
        }
        lastFloatSpeedValText = speedVal
        lastFloatSpeedUnitText = speedUnit
        lastFloatSpeedPx = px
        val bmp = createBitmapFromString(arrayOf(speedVal, speedUnit), size = 0.60f, px = px, refText = "99.9")
        lastFloatSpeedBitmap = bmp
        return bmp
    }
}
