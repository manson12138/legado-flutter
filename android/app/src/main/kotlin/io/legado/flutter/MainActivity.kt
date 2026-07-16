package io.legado.flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log

/**
 * Flutter Android 宿主入口。
 *
 * M1 的 edge-to-edge 与安全区域策略由 Dart 组合根统一配置；M08 只在这里实现窗口常亮，
 * 不把书籍、章节或阅读进度复制到 Kotlin。
 */
class MainActivity : FlutterActivity() {

    /** 阅读器平台通道名称，必须与 Dart ReaderPlatformService 保持一致。 */
    private val readerPlatformChannel = "io.legado.flutter/reader_platform"

    /** Dart 日志写入 Android Logcat 使用的平台通道名称。 */
    private val loggingPlatformChannel = "io.legado.flutter/logging"

    /** 首次进入阅读器前窗口是否已经由其他功能设置常亮；退出时据此恢复。 */
    private var originalKeepScreenOn: Boolean? = null

    /** 注册 M08 阅读器最小平台通道。 */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerLoggingChannel(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            readerPlatformChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "enterReader" -> {
                    /** Dart 传入的初始常亮状态；缺失参数安全回退为关闭。 */
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    enterReaderWindow(enabled)
                    result.success(null)
                }

                "setKeepScreenOn" -> {
                    /** Dart 传入的目标常亮状态；缺失参数安全回退为关闭。 */
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    setReaderKeepScreenOn(enabled)
                    result.success(null)
                }

                "exitReader" -> {
                    exitReaderWindow()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    /** 注册日志通道，使 Android Studio Logcat 可以按业务 Tag 直接筛选。 */
    private fun registerLoggingChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            loggingPlatformChannel,
        ).setMethodCallHandler { call, result ->
            if (call.method != "log") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            /** Dart 传入的日志优先级；未知值安全回退为 info。 */
            val level = call.argument<String>("level") ?: "info"
            /** Dart 传入的 Logcat Tag；空值安全回退为普通应用 Tag。 */
            val tag = call.argument<String>("tag") ?: "LEGADO_APP"
            /** Dart 已经按安全长度拆分的日志正文。 */
            val message = call.argument<String>("message") ?: ""
            writeLogcat(level = level, tag = tag, message = message)
            result.success(null)
        }
    }

    /** 按日志优先级调用对应的 android.util.Log 方法。 */
    private fun writeLogcat(level: String, tag: String, message: String) {
        when (level) {
            "debug" -> Log.d(tag, message)
            "warning" -> Log.w(tag, message)
            "error" -> Log.e(tag, message)
            "fatal" -> Log.wtf(tag, message)
            else -> Log.i(tag, message)
        }
    }

    /** 进入阅读器时记录原始常亮状态，再应用本书配置。 */
    private fun enterReaderWindow(enabled: Boolean) {
        if (originalKeepScreenOn == null) {
            originalKeepScreenOn =
                window.attributes.flags and android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
        }
        setReaderKeepScreenOn(enabled)
    }

    /** 阅读中按设置更新窗口常亮，不改写已经保存的原始状态。 */
    private fun setReaderKeepScreenOn(enabled: Boolean) {
        if (enabled) {
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            return
        }
        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    /** 离开阅读器时恢复进入前的窗口常亮状态。 */
    private fun exitReaderWindow() {
        /** 阅读器进入前的原始常亮状态。 */
        val restoreKeepScreenOn = originalKeepScreenOn ?: return
        if (restoreKeepScreenOn) {
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        originalKeepScreenOn = null
    }
}
