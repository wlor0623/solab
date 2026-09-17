package zhou.solab

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import io.flutter.embedding.engine.FlutterEngine

/**
 * 自研保活前台服务（替代停更的 flutter_background.IsolateHolderService）。
 *
 * 保活四件套：
 * 1. FGS — 提升进程优先级，系统不轻易回收。类型按版本分派：
 *    API 35+ 用 SPECIAL_USE（Android 15 对 dataSync 有 6h 强限时，到时 FGS
 *    被停→进程降级为 cached→被 freezer 冻结→后台 MCP 工具全部无响应，
 *    曾致「进程还在但后台工具失效」）；API 29-34 用 DATA_SYNC（无限时）。
 * 2. PARTIAL_WAKE_LOCK — 防 Doze/国产 ROM 限流 CPU 导致流式输出与工具执行卡死
 * 3. WIFI_LOCK(low-latency) — 防 Wi-Fi radio 进省电模式后入站 TCP 连接收不到
 *    （MCP server 依赖局域网入站连接，radio 睡眠=后台连接全部超时）
 * 4. START_STICKY — 进程被杀后系统尝试重建
 *
 * agent 模式（生成期持有）与 MCP 模式（常驻开关）共用此服务。
 */
class KeepAliveService : Service(), LifecycleOwner {
    companion object {
        const val CHANNEL_ID = "solab_keepalive"
        const val NOTIFICATION_ID = 20260816
        const val ACTION_START = "zhou.solab.KEEPALIVE_START"
        const val ACTION_STOP = "zhou.solab.KEEPALIVE_STOP"
        private const val STATE_PREFS = "keepalive_state"
        private const val KEY_TITLE = "title"
        private const val KEY_TEXT = "text"
        private const val KEY_NETWORK_REQUIRED = "network_required"
        private const val OVERLAY_PREFS = "keepalive_overlay"
        private const val KEY_OVERLAY_ENABLED = "enabled"

        @Volatile
        var isRunning = false
            private set

        @Volatile
        private var wakeLock: PowerManager.WakeLock? = null

        @Volatile
        private var wifiLock: WifiManager.WifiLock? = null

        @Volatile
        private var currentService: KeepAliveService? = null

        @Volatile
        private var overlayEnabled = true

        internal fun attachFlutterEngineToService() {
            currentService?.attachFlutterEngineIfNeeded()
        }

        internal fun detachFlutterEngineFromService() {
            currentService?.detachFlutterEngine()
        }

        internal fun onActivityVisibilityChanged(visible: Boolean) {
            currentService?.updateOverlayVisibility(visible)
        }

        internal fun refreshOverlay() {
            currentService?.updateOverlayVisibility(MainActivity.hasVisibleActivity())
        }

        fun isOverlayEnabled(context: Context): Boolean =
            context.getSharedPreferences(OVERLAY_PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_OVERLAY_ENABLED, true)

        fun setOverlayEnabled(context: Context, enabled: Boolean) {
            overlayEnabled = enabled
            context.getSharedPreferences(OVERLAY_PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_OVERLAY_ENABLED, enabled).apply()
            currentService?.updateOverlayVisibility(MainActivity.hasVisibleActivity())
        }

        fun start(
            context: Context,
            title: String,
            text: String,
            networkRequired: Boolean,
        ) {
            val intent = Intent(context, KeepAliveService::class.java).apply {
                action = ACTION_START
                putExtra("title", title)
                putExtra("text", text)
                putExtra("networkRequired", networkRequired)
            }
            // 调用时机都在前台或进程已持 FGS（生成期/常驻开启），
            // startForegroundService 合法；Android 12+ 后台启动限制不在此路径。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.getSharedPreferences(STATE_PREFS, Context.MODE_PRIVATE)
                .edit().clear().apply()
            releaseLocks()
            context.stopService(Intent(context, KeepAliveService::class.java))
        }

        fun isReady(networkRequired: Boolean): Boolean =
            isRunning &&
                (!networkRequired ||
                    (wakeLock?.isHeld == true && wifiLock?.isHeld == true))

        private fun releaseLocks() {
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = null
            wifiLock?.let { if (it.isHeld) it.release() }
            wifiLock = null
            isRunning = false
        }
    }

    private val lifecycleRegistry = LifecycleRegistry(this)
    private var attachedEngine: FlutterEngine? = null
    private var overlayView: View? = null
    private var overlayIconView: View? = null
    private var overlayParams: WindowManager.LayoutParams? = null
    private val overlayHandler = Handler(Looper.getMainLooper())
    private val snapOverlayRunnable = Runnable { snapOverlayToEdge() }
    override val lifecycle: Lifecycle get() = lifecycleRegistry

    override fun onCreate() {
        super.onCreate()
        currentService = this
        overlayEnabled = isOverlayEnabled(applicationContext)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val state = getSharedPreferences(STATE_PREFS, Context.MODE_PRIVATE)
        val title = intent?.getStringExtra("title")
            ?: state.getString(KEY_TITLE, null)
            ?: "SoLab"
        val text = intent?.getStringExtra("text")
            ?: state.getString(KEY_TEXT, null)
            ?: "后台任务保活中"
        val networkRequired = if (intent?.hasExtra("networkRequired") == true) {
            intent.getBooleanExtra("networkRequired", false)
        } else {
            state.getBoolean(KEY_NETWORK_REQUIRED, false)
        }
        state.edit()
            .putString(KEY_TITLE, title)
            .putString(KEY_TEXT, text)
            .putBoolean(KEY_NETWORK_REQUIRED, networkRequired)
            .apply()

        val notification = buildNotification(title, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            // Android 15+：dataSync 有 6h 系统限时，用 specialUse 免限时
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // WakeLock 与 FGS 生命周期绑定；服务停止时统一释放。
        if (networkRequired && wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "solab:keepalive",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        // WifiLock：MCP server 依赖局域网入站连接；后台时 Wi-Fi radio 省电
        // 会让入站 SYN 收不到，表现为「进程活着但工具全部超时」。
        if (networkRequired && wifiLock == null) {
            @Suppress("DEPRECATION")
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wm != null) {
                @Suppress("DEPRECATION")
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "solab:mcpserver").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        }
        if (!networkRequired) {
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = null
            wifiLock?.let { if (it.isHeld) it.release() }
            wifiLock = null
        }
        isRunning = true
        updateOverlayVisibility(MainActivity.hasVisibleActivity())
        if (networkRequired) {
            // FGS 只能保住进程。任务界面被移除时 FlutterActivity 会销毁，若不保留
            // Dart 引擎，进程和通知仍在但 MCP socket/工具执行器已经消失。
            // 缓存引擎覆盖界面移除；START_STICKY 重建服务时在无界面状态补建引擎。
            MainActivity.ensurePersistentFlutterEngine(applicationContext)
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_START)
            attachFlutterEngineIfNeeded()
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Handler(Looper.getMainLooper()).postDelayed(
            { attachFlutterEngineIfNeeded() },
            250,
        )
        super.onTaskRemoved(rootIntent)
    }

    // FGS 类型系统限时兜底（specialUse 正常不触发；防系统策略变化导致 crash）
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        removeOverlay()
        detachFlutterEngine()
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
        if (currentService === this) currentService = null
        releaseLocks()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun attachFlutterEngineIfNeeded() {
        if (!isRunning || MainActivity.hasAttachedActivity()) return
        val engine = MainActivity.ensurePersistentFlutterEngine(applicationContext)
        if (attachedEngine === engine) {
            engine.lifecycleChannel.appIsResumed()
            return
        }
        detachFlutterEngine()
        engine.serviceControlSurface.attachToService(this, lifecycle, true)
        engine.lifecycleChannel.appIsResumed()
        attachedEngine = engine
    }

    private fun detachFlutterEngine() {
        val engine = attachedEngine ?: return
        runCatching { engine.serviceControlSurface.detachFromService() }
        attachedEngine = null
    }

    private fun updateOverlayVisibility(activityVisible: Boolean) {
        if (!isRunning || !overlayEnabled || activityVisible ||
            Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            !Settings.canDrawOverlays(this)
        ) {
            removeOverlay()
            return
        }
        if (overlayView != null) return

        val density = resources.displayMetrics.density
        val size = (40 * density).toInt()
        val icon = ImageView(this).apply {
            setImageDrawable(applicationInfo.loadIcon(packageManager))
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.TRANSPARENT)
            }
            outlineProvider = ViewOutlineProvider.BACKGROUND
            clipToOutline = true
            contentDescription = applicationInfo.loadLabel(packageManager)
        }
        val badge = FrameLayout(this).apply {
            clipChildren = true
            addView(
                icon,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                ),
            )
        }
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            size,
            size,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            val (screenWidth, screenHeight) = overlayScreenSize()
            x = screenWidth - size
            y = (screenHeight - size) / 2
        }
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        var downRawX = 0f
        var downRawY = 0f
        var downX = 0
        var downY = 0
        badge.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    overlayHandler.removeCallbacks(snapOverlayRunnable)
                    icon.animate().cancel()
                    icon.translationX = 0f
                    downRawX = event.rawX
                    downRawY = event.rawY
                    downX = params.x
                    downY = params.y
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    val (screenWidth, screenHeight) = overlayScreenSize()
                    params.x = (downX + dx.toInt()).coerceIn(0, screenWidth - size)
                    params.y = (downY + dy.toInt()).coerceIn(0, screenHeight - size)
                    runCatching { wm.updateViewLayout(view, params) }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    scheduleOverlaySnap()
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    scheduleOverlaySnap()
                    true
                }
                else -> false
            }
        }
        runCatching { wm.addView(badge, params) }
            .onSuccess {
                overlayView = badge
                overlayIconView = icon
                overlayParams = params
                scheduleOverlaySnap()
            }
    }

    private fun removeOverlay() {
        overlayHandler.removeCallbacks(snapOverlayRunnable)
        val view = overlayView ?: return
        overlayView = null
        overlayIconView = null
        overlayParams = null
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        runCatching { wm.removeView(view) }
    }

    private fun scheduleOverlaySnap() {
        overlayHandler.removeCallbacks(snapOverlayRunnable)
        overlayHandler.postDelayed(snapOverlayRunnable, 3_000)
    }

    private fun snapOverlayToEdge() {
        val view = overlayView ?: return
        val params = overlayParams ?: return
        val icon = overlayIconView ?: return
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val (screenWidth, _) = overlayScreenSize()
        val visibleWidth = (10 * resources.displayMetrics.density).toInt()
        val snapLeft = params.x + params.width / 2 < screenWidth / 2
        params.x = if (snapLeft) {
            0
        } else {
            screenWidth - params.width
        }
        runCatching { wm.updateViewLayout(view, params) }
        icon.animate()
            .translationX(
                if (snapLeft) {
                    -(params.width - visibleWidth).toFloat()
                } else {
                    (params.width - visibleWidth).toFloat()
                },
            )
            .setDuration(160)
            .start()
    }

    private fun overlayScreenSize(): Pair<Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = wm.currentWindowMetrics.bounds
            bounds.width() to bounds.height()
        } else {
            @Suppress("DEPRECATION")
            resources.displayMetrics.run { widthPixels to heightPixels }
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "后台保活",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                setShowBadge(false)
            }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, text: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pending = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(pending)
            .build()
    }
}
