package com.hinter.hinter

import android.content.Context
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 未捕获异常落盘:闪退时把完整堆栈写到 files/last_crash.txt,
 * 下次启动通过 hinter/diag 通道暴露给 Dart 展示,便于用户反馈。
 */
class CrashReporter(context: Context) : Thread.UncaughtExceptionHandler {
    private val prev = Thread.getDefaultUncaughtExceptionHandler()
    private val file = File(context.filesDir, "last_crash.txt")

    override fun uncaughtException(t: Thread, e: Throwable) {
        try {
            val ts = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
            file.writeText("time=$ts\nthread=${t.name}\n${Log.getStackTraceString(e)}")
        } catch (_: Exception) {
        }
        prev?.uncaughtException(t, e)
    }

    companion object {
        fun install(context: Context) {
            Thread.setDefaultUncaughtExceptionHandler(CrashReporter(context.applicationContext))
        }
    }
}

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        readDebugRot(intent)
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        readDebugRot(intent)
    }

    /** adb: am start -n com.hinter.hinter/.MainActivity --ei debug_rot 90 */
    private fun readDebugRot(intent: android.content.Intent?) {
        val v = intent?.getIntExtra("debug_rot", -1) ?: -1
        if (v >= 0) {
            com.hinter.hinter.camera.HinterCameraPlugin.debugRot = v % 360
            android.util.Log.i("HinterCamera", "debugRot set to $v")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        CrashReporter.install(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hinter/diag")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getLastCrash" -> {
                        val f = File(applicationContext.filesDir, "last_crash.txt")
                        result.success(if (f.exists()) f.readText() else null)
                    }
                    "clearCrash" -> {
                        val f = File(applicationContext.filesDir, "last_crash.txt")
                        if (f.exists()) f.delete()
                        result.success(null)
                    }
                    "deviceInfo" -> {
                        // 设备能力探测:供 Dart 侧判定"配置不足以运行"并提示
                        val am = getSystemService(Context.ACTIVITY_SERVICE)
                                as android.app.ActivityManager
                        val mi = android.app.ActivityManager.MemoryInfo()
                        am.getMemoryInfo(mi)
                        val stat = android.os.StatFs(filesDir.path)
                        result.success(mapOf(
                            "sdkInt" to android.os.Build.VERSION.SDK_INT,
                            "totalMemMb" to (mi.totalMem / 1048576.0),
                            "availMemMb" to (mi.availMem / 1048576.0),
                            "cores" to Runtime.getRuntime().availableProcessors(),
                            "freeDiskMb" to (stat.availableBytes / 1048576.0),
                            "model" to android.os.Build.MODEL
                        ))
                    }
                    else -> result.notImplemented()
                }
            }
        flutterEngine.plugins.add(com.hinter.hinter.camera.HinterCameraPlugin())
    }
}
