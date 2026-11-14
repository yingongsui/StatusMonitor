package com.yin.statusmonitor

import android.app.Activity
import android.app.Dialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import kotlin.math.min

class LinkOpenerActivity : Activity() {

    private data class TargetApp(
        val resolveInfo: ResolveInfo,
        val label: String,
        val isSpecificAppHandler: Boolean
    )

    private var activeDialog: Dialog? = null
    private var isClosing = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        if (intent != null) {
            setIntent(intent)
            activeDialog?.dismiss()
            handleIncomingIntent(intent)
        }
    }

    private fun handleIncomingIntent(incoming: Intent?) {
        val uri = incoming?.data
        if (uri == null || uri.scheme.isNullOrBlank()) {
            closeSafely()
            return
        }

        val targets = resolveTargetApps(uri)
        showBrowserChooserDialog(uri, targets)
    }

    private fun resolveTargetApps(uri: Uri): List<TargetApp> {
        val scheme = uri.scheme?.lowercase() ?: "https"
        val genericBrowserIntent = Intent(Intent.ACTION_VIEW, Uri.parse("$scheme://example.com")).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
        }
        val specificIntent = Intent(Intent.ACTION_VIEW, uri).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
        }

        val genericResults = queryMatchingActivities(genericBrowserIntent)
        val specificResults = queryMatchingActivities(specificIntent)

        val genericKeys = genericResults.map { componentKey(it) }.toHashSet()
        val combined = LinkedHashMap<String, TargetApp>()

        for (info in specificResults) {
            val actInfo = info.activityInfo ?: continue
            if (!actInfo.exported) continue
            if (actInfo.packageName == packageName || actInfo.packageName == "android") continue

            val key = componentKey(info)
            if (!combined.containsKey(key)) {
                val label = info.loadLabel(packageManager)?.toString()?.trim().orEmpty()
                    .ifEmpty { actInfo.packageName }
                combined[key] = TargetApp(
                    resolveInfo = info,
                    label = label,
                    isSpecificAppHandler = !genericKeys.contains(key)
                )
            }
        }

        for (info in genericResults) {
            val actInfo = info.activityInfo ?: continue
            if (!actInfo.exported) continue
            if (actInfo.packageName == packageName || actInfo.packageName == "android") continue

            val key = componentKey(info)
            if (!combined.containsKey(key)) {
                val label = info.loadLabel(packageManager)?.toString()?.trim().orEmpty()
                    .ifEmpty { actInfo.packageName }
                combined[key] = TargetApp(
                    resolveInfo = info,
                    label = label,
                    isSpecificAppHandler = false
                )
            }
        }

        return combined.values.sortedWith(
            compareBy<TargetApp> { !it.isSpecificAppHandler }
                .thenBy { it.label.lowercase() }
        )
    }

    private fun queryMatchingActivities(intent: Intent): List<ResolveInfo> {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.queryIntentActivities(
                    intent,
                    PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_ALL.toLong())
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.queryIntentActivities(intent, PackageManager.MATCH_ALL)
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun componentKey(info: ResolveInfo): String {
        val act = info.activityInfo
        return "${act.packageName}/${act.name}"
    }

    private fun showBrowserChooserDialog(uri: Uri, targets: List<TargetApp>) {
        val isDark = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

        val cardBg = if (isDark) Color.parseColor("#161A22") else Color.WHITE
        val cardBorder = if (isDark) Color.parseColor("#2A3140") else Color.parseColor("#E2E8F0")
        val urlBoxBg = if (isDark) Color.parseColor("#0D1117") else Color.parseColor("#F1F5F9")
        val primaryText = if (isDark) Color.WHITE else Color.parseColor("#0F172A")
        val secondaryText = if (isDark) Color.parseColor("#9CA3AF") else Color.parseColor("#64748B")
        val accentColor = if (isDark) Color.parseColor("#22D3EE") else Color.parseColor("#0284C7")
        val badgeBg = if (isDark) Color.parseColor("#1E293B") else Color.parseColor("#E0F2FE")
        val dividerColor = if (isDark) Color.parseColor("#242B38") else Color.parseColor("#E2E8F0")

        val dialog = Dialog(this)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        dialog.setCanceledOnTouchOutside(true)

        val rootContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(14))
            background = GradientDrawable().apply {
                setColor(cardBg)
                cornerRadius = dpF(22)
                setStroke(dp(1), cardBorder)
            }
        }

        // Title
        val titleView = TextView(this).apply {
            text = "Open link with"
            setTextColor(primaryText)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setTypeface(null, Typeface.BOLD)
        }
        rootContainer.addView(titleView)

        // URL preview & Copy button box
        val urlCard = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(10), dp(8), dp(10))
            background = GradientDrawable().apply {
                setColor(urlBoxBg)
                cornerRadius = dpF(12)
                setStroke(dp(1), cardBorder)
            }
        }
        val urlParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply {
            topMargin = dp(12)
            bottomMargin = dp(12)
        }

        val urlTextCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        val hostText = TextView(this).apply {
            text = uri.host?.takeIf { it.isNotBlank() } ?: uri.scheme ?: "Web Link"
            setTextColor(primaryText)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setTypeface(null, Typeface.BOLD)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        val fullUrlText = TextView(this).apply {
            text = uri.toString()
            setTextColor(secondaryText)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
        }
        urlTextCol.addView(hostText)
        urlTextCol.addView(fullUrlText)

        urlCard.addView(
            urlTextCol,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )

        val copyButton = TextView(this).apply {
            text = "Copy"
            setTextColor(accentColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setTypeface(null, Typeface.BOLD)
            setPadding(dp(10), dp(6), dp(10), dp(6))
            isClickable = true
            isFocusable = true
            setRippleBackground(this)
            setOnClickListener {
                copyUrlToClipboard(uri.toString())
            }
        }
        urlCard.addView(copyButton)
        rootContainer.addView(urlCard, urlParams)

        // Browser List or Empty State
        if (targets.isEmpty()) {
            val emptyView = TextView(this).apply {
                text = "No other browsers found on this device."
                setTextColor(secondaryText)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                gravity = Gravity.CENTER
                setPadding(dp(12), dp(24), dp(12), dp(24))
            }
            rootContainer.addView(emptyView)
        } else {
            val scrollView = ScrollView(this)
            val listLayout = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
            }

            targets.forEachIndexed { index, target ->
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    minimumHeight = dp(52)
                    setPadding(dp(8), dp(8), dp(8), dp(8))
                    isClickable = true
                    isFocusable = true
                    setRippleBackground(this)
                    setOnClickListener {
                        launchWithTarget(uri, target)
                    }
                }

                val iconView = ImageView(this).apply {
                    scaleType = ImageView.ScaleType.FIT_CENTER
                    try {
                        setImageDrawable(target.resolveInfo.loadIcon(packageManager))
                    } catch (_: Exception) {
                        setImageResource(android.R.drawable.sym_def_app_icon)
                    }
                }
                row.addView(iconView, LinearLayout.LayoutParams(dp(36), dp(36)))

                val labelView = TextView(this).apply {
                    text = target.label
                    setTextColor(primaryText)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                    setTypeface(null, Typeface.NORMAL)
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                    setPadding(dp(14), 0, dp(8), 0)
                }
                row.addView(
                    labelView,
                    LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                )

                if (target.isSpecificAppHandler) {
                    val badge = TextView(this).apply {
                        text = "App"
                        setTextColor(accentColor)
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
                        setTypeface(null, Typeface.BOLD)
                        setPadding(dp(8), dp(3), dp(8), dp(3))
                        background = GradientDrawable().apply {
                            setColor(badgeBg)
                            cornerRadius = dpF(8)
                        }
                    }
                    row.addView(badge)
                }

                listLayout.addView(
                    row,
                    LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT
                    )
                )

                if (index < targets.lastIndex) {
                    val divider = View(this).apply {
                        setBackgroundColor(dividerColor)
                    }
                    listLayout.addView(
                        divider,
                        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1)).apply {
                            leftMargin = dp(58)
                        }
                    )
                }
            }

            scrollView.addView(listLayout)
            val maxListHeight = (resources.displayMetrics.heightPixels * 0.50).toInt()
            scrollView.measure(
                View.MeasureSpec.makeMeasureSpec(
                    resources.displayMetrics.widthPixels - dp(80),
                    View.MeasureSpec.AT_MOST
                ),
                View.MeasureSpec.makeMeasureSpec(maxListHeight, View.MeasureSpec.AT_MOST)
            )
            val measuredHeight = min(scrollView.measuredHeight, maxListHeight)
            rootContainer.addView(
                scrollView,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    if (measuredHeight > 0) measuredHeight else ViewGroup.LayoutParams.WRAP_CONTENT
                )
            )
        }

        // Bottom Footer (Cancel)
        val footerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            setPadding(0, dp(10), 0, 0)
        }
        val cancelBtn = TextView(this).apply {
            text = "Cancel"
            setTextColor(secondaryText)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTypeface(null, Typeface.BOLD)
            setPadding(dp(16), dp(10), dp(12), dp(10))
            isClickable = true
            isFocusable = true
            setRippleBackground(this)
            setOnClickListener {
                closeSafely()
            }
        }
        footerRow.addView(cancelBtn)
        rootContainer.addView(footerRow)

        dialog.setContentView(rootContainer)
        dialog.window?.let { win ->
            win.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            val maxWidth = min(resources.displayMetrics.widthPixels - dp(40), dp(420))
            win.setLayout(maxWidth, ViewGroup.LayoutParams.WRAP_CONTENT)
            win.setGravity(Gravity.CENTER)
        }

        dialog.setOnCancelListener { closeSafely() }
        dialog.setOnDismissListener {
            if (!isClosing) {
                closeSafely()
            }
        }

        activeDialog = dialog
        dialog.show()
    }

    private fun launchWithTarget(uri: Uri, target: TargetApp) {
        try {
            val actInfo = target.resolveInfo.activityInfo
            val launchIntent = Intent(Intent.ACTION_VIEW, uri).apply {
                component = ComponentName(actInfo.packageName, actInfo.name)
                `package` = actInfo.packageName
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(launchIntent)
            closeSafely()
        } catch (_: Exception) {
            Toast.makeText(this, "Unable to open with ${target.label}", Toast.LENGTH_SHORT).show()
        }
    }

    private fun copyUrlToClipboard(url: String) {
        try {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            clipboard?.setPrimaryClip(ClipData.newPlainText("URL", url))
            Toast.makeText(this, "Link copied to clipboard", Toast.LENGTH_SHORT).show()
        } catch (_: Exception) {}
    }

    private fun setRippleBackground(view: View) {
        val outValue = TypedValue()
        if (theme.resolveAttribute(android.R.attr.selectableItemBackground, outValue, true)) {
            view.setBackgroundResource(outValue.resourceId)
        }
    }

    private fun closeSafely() {
        if (isClosing) return
        isClosing = true
        try {
            activeDialog?.dismiss()
        } catch (_: Exception) {}
        activeDialog = null
        if (!isFinishing && !isDestroyed) {
            if (isTaskRoot) {
                finishAndRemoveTask()
            } else {
                finish()
            }
        }
    }

    override fun onDestroy() {
        isClosing = true
        try {
            activeDialog?.dismiss()
        } catch (_: Exception) {}
        activeDialog = null
        super.onDestroy()
    }

    private fun dp(value: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics
        ).toInt()
    }

    private fun dpF(value: Int): Float {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics
        )
    }
}
