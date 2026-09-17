package zhou.solab

import android.app.Activity
import android.content.ActivityNotFoundException
import android.net.Uri
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    companion object {
        const val CREATE_DOCUMENT_REQUEST_CODE = 4107
        private const val PERSISTENT_ENGINE_ID = "solab-persistent-engine"
        @Volatile private var attachedActivity: MainActivity? = null
        @Volatile private var activityVisible = false

        internal fun hasAttachedActivity(): Boolean = attachedActivity != null
        internal fun hasVisibleActivity(): Boolean = activityVisible

        @Synchronized
        internal fun ensurePersistentFlutterEngine(context: Context): FlutterEngine {
            FlutterEngineCache.getInstance().get(PERSISTENT_ENGINE_ID)?.let { return it }
            return FlutterEngine(context.applicationContext).also { engine ->
                FlutterEngineCache.getInstance().put(PERSISTENT_ENGINE_ID, engine)
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint.createDefault(),
                )
            }
        }
    }

    private val processTextChannelName = "app.process_text"
    private val fileSaveChannelName = "app.file_save"
    private val backgroundChannelName = "app.background"
    private var processTextChannel: MethodChannel? = null
    private var fileSaveChannel: MethodChannel? = null
    private var backgroundChannel: MethodChannel? = null
    private var pendingProcessText: String? = null
    private var requestOverlayAfterResume = false
     private var pendingSaveResult: MethodChannel.Result? = null
     private var pendingSaveSourcePath: String? = null
     private var deviceLocalToolsHandler: DeviceLocalToolsHandler? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        attachedActivity = this
        KeepAliveService.detachFlutterEngineFromService()
        super.onCreate(savedInstanceState)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(PERSISTENT_ENGINE_ID)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        FlutterEngineCache.getInstance().put(PERSISTENT_ENGINE_ID, flutterEngine)
        super.configureFlutterEngine(flutterEngine)
        // M3/M5: SO 引擎基础设施初始化（日志 + Rizin Ghidra 伪代码插件配置）
        zhou.solab.tools.AppLog.init(applicationContext)
        zhou.solab.tools.KotlinToolStats.init(applicationContext)
        runCatching {
            zhou.solab.nativecore.RizinNativeEngine.configureGhidra(applicationContext)
        }
        McpOAuthHandler.configure(this, flutterEngine.dartExecutor.binaryMessenger)
        SolabChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        backgroundChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, backgroundChannelName)
        backgroundChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // 自研保活（FGS + WakeLock）：agent 模式生成期持有，MCP 模式常驻开关
                "keepAliveStart" -> {
                    val title = call.argument<String>("title") ?: "SoLab"
                    val text = call.argument<String>("text") ?: "后台任务保活中"
                    val networkRequired = call.argument<Boolean>("networkRequired") ?: false
                    runCatching {
                        KeepAliveService.start(applicationContext, title, text, networkRequired)
                        result.success(true)
                    }.onFailure {
                        // Android 12+ 后台启动 FGS 受限等场景：不抛错，
                        // 返回 false 让 Dart 侧记录 lastEnableError 并向用户提示。
                        result.success(false)
                    }
                }
                "keepAliveRefreshNotification" -> {
                    // 通知权限刚授予时重发前台通知（Android 13+ FGS 在未授权
                    // 时其通知被系统隐藏，授权后需重发才立即可见）。
                    val title = call.argument<String>("title") ?: "SoLab"
                    val text = call.argument<String>("text") ?: "后台任务保活中"
                    val networkRequired = call.argument<Boolean>("networkRequired") ?: false
                    runCatching {
                        KeepAliveService.start(applicationContext, title, text, networkRequired)
                        result.success(KeepAliveService.isRunning)
                    }.onFailure { result.success(false) }
                }
                "keepAliveStop" -> {
                    runCatching { KeepAliveService.stop(applicationContext) }
                    result.success(true)
                }
                "keepAliveIsRunning" -> result.success(KeepAliveService.isRunning)
                "keepAliveIsReady" -> {
                    val networkRequired = call.argument<Boolean>("networkRequired") ?: false
                    result.success(KeepAliveService.isReady(networkRequired))
                }
                "isIgnoringBatteryOptimizations" -> {
                    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "requestIgnoreBatteryOptimizations" -> {
                    // 用户显式开启保活/常驻时引导豁免，防止国产 ROM 冻结进程
                    runCatching {
                        requestOverlayAfterResume =
                            KeepAliveService.isOverlayEnabled(applicationContext) &&
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                                !Settings.canDrawOverlays(this)
                        val intent = Intent(
                            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            Uri.parse("package:$packageName"),
                        )
                        startActivity(intent)
                        result.success(true)
                    }.onFailure { result.success(false) }
                }
                "isOverlayPermissionGranted" -> {
                    result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                            Settings.canDrawOverlays(this),
                    )
                }
                "requestOverlayPermission" -> {
                    result.success(openOverlayPermissionSettings())
                }
                "isKeepAliveOverlayEnabled" -> {
                    result.success(KeepAliveService.isOverlayEnabled(applicationContext))
                }
                "setKeepAliveOverlayEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    KeepAliveService.setOverlayEnabled(applicationContext, enabled)
                    result.success(true)
                }
                "requestKeepAlivePermissions" -> {
                    val force = call.argument<Boolean>("force") ?: false
                    result.success(requestKeepAlivePermissions(force))
                }
                else -> result.notImplemented()
            }
        }
        McpOAuthHandler.configure(this, flutterEngine.dartExecutor.binaryMessenger)
        deviceLocalToolsHandler = DeviceLocalToolsHandler(this).also {
            it.configure(flutterEngine.dartExecutor.binaryMessenger)
        }
        processTextChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, processTextChannelName)
        processTextChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialText" -> {
                    val text = pendingProcessText ?: extractProcessText(intent)
                    pendingProcessText = null
                    result.success(text)
                }
                else -> result.notImplemented()
            }
        }
        fileSaveChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileSaveChannelName)
        fileSaveChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFileFromPath" -> handleSaveFileFromPath(call.arguments, result)
                else -> result.notImplemented()
            }
        }
        pendingProcessText = extractProcessText(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = extractProcessText(intent) ?: return
        val ch = processTextChannel
        if (ch != null) {
            ch.invokeMethod("onProcessText", text)
        } else {
            pendingProcessText = text
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (attachedActivity === this) attachedActivity = null
        KeepAliveService.attachFlutterEngineToService()
    }

    override fun onStart() {
        super.onStart()
        activityVisible = true
        KeepAliveService.onActivityVisibilityChanged(true)
    }

    override fun onResume() {
        super.onResume()
        if (requestOverlayAfterResume) {
            requestOverlayAfterResume = false
            window.decorView.post { openOverlayPermissionSettings() }
        } else {
            KeepAliveService.refreshOverlay()
        }
    }

    override fun onStop() {
        activityVisible = false
        KeepAliveService.onActivityVisibilityChanged(false)
        super.onStop()
    }

    private fun requestKeepAlivePermissions(force: Boolean): Boolean {
        val prefs = getSharedPreferences("keepalive_permissions", Context.MODE_PRIVATE)
        if (!force && prefs.getBoolean("prompted", false)) {
            KeepAliveService.refreshOverlay()
            return true
        }
        prefs.edit().putBoolean("prompted", true).apply()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                requestOverlayAfterResume =
                    KeepAliveService.isOverlayEnabled(applicationContext) &&
                        !Settings.canDrawOverlays(this)
                return runCatching {
                    startActivity(
                        Intent(
                            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                    true
                }.getOrDefault(false)
            }
            if (KeepAliveService.isOverlayEnabled(applicationContext) &&
                !Settings.canDrawOverlays(this)
            ) {
                return openOverlayPermissionSettings()
            }
        }
        KeepAliveService.refreshOverlay()
        return true
    }

    private fun openOverlayPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)) {
            KeepAliveService.refreshOverlay()
            return true
        }
        return runCatching {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName"),
                ),
            )
            true
        }.getOrDefault(false)
    }
 
     override fun onRequestPermissionsResult(
         requestCode: Int,
         permissions: Array<out String>,
         grantResults: IntArray,
     ) {
         if (deviceLocalToolsHandler?.onRequestPermissionsResult(requestCode, grantResults) == true) {
             return
         }
         super.onRequestPermissionsResult(requestCode, permissions, grantResults)
     }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != CREATE_DOCUMENT_REQUEST_CODE) {
            return
        }

        val destUri = if (resultCode == Activity.RESULT_OK) data?.data else null
        handleSaveDestination(destUri)
    }

    private fun extractProcessText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_PROCESS_TEXT) return null
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        return text?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun handleSaveFileFromPath(arguments: Any?, result: MethodChannel.Result) {
        if (pendingSaveResult != null) {
            result.error("busy", "Another save operation is already in progress.", null)
            return
        }

        val args = arguments as? Map<*, *>
        val rawSourcePath = args?.get("sourcePath")?.toString()?.trim().orEmpty()
        if (rawSourcePath.isEmpty()) {
            result.error("invalid_args", "Missing sourcePath.", null)
            return
        }

        val sourceFile = File(rawSourcePath)
        if (!sourceFile.exists() || !sourceFile.isFile) {
            result.error("not_found", "Source file does not exist.", null)
            return
        }

        val suggestedFileName = args?.get("fileName")?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
            ?: sourceFile.name

        pendingSaveResult = result
        pendingSaveSourcePath = sourceFile.absolutePath

        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/zip"
                putExtra(Intent.EXTRA_TITLE, suggestedFileName)
            }
            startActivityForResult(intent, CREATE_DOCUMENT_REQUEST_CODE)
        } catch (e: ActivityNotFoundException) {
            pendingSaveResult = null
            pendingSaveSourcePath = null
            result.error("launch_failed", e.message, null)
        }
    }

    private fun handleSaveDestination(destUri: Uri?) {
        val result = pendingSaveResult ?: return
        val sourcePath = pendingSaveSourcePath

        if (destUri == null || sourcePath.isNullOrBlank()) {
            pendingSaveResult = null
            pendingSaveSourcePath = null
            result.success(false)
            return
        }

        Thread {
            try {
                contentResolver.openOutputStream(destUri)?.use { outputStream ->
                    FileInputStream(File(sourcePath)).use { inputStream ->
                        inputStream.copyTo(outputStream, DEFAULT_BUFFER_SIZE)
                    }
                } ?: throw IllegalStateException("Unable to open destination stream.")

                runOnUiThread {
                    pendingSaveResult = null
                    pendingSaveSourcePath = null
                    try {
                        result.success(true)
                    } catch (_: Exception) {
                        // 通道已销毁/重复回复时不得崩 UI 线程。
                    }
                }
            } catch (e: Exception) {
                runOnUiThread {
                    pendingSaveResult = null
                    pendingSaveSourcePath = null
                    try {
                        result.error("save_failed", e.message, null)
                    } catch (_: Exception) {
                        // 通道已销毁/重复回复时不得崩 UI 线程。
                    }
                }
            }
        }.start()
    }
}
