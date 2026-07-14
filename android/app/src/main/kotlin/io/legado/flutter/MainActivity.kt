package io.legado.flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter Android 宿主入口。
 *
 * M1 的 edge-to-edge 与安全区域策略由 Dart 组合根统一配置；M08 只在这里实现窗口常亮，
 * 不把书籍、章节或阅读进度复制到 Kotlin。
 */
class MainActivity : FlutterActivity() {

    /** 阅读器平台通道名称，必须与 Dart ReaderPlatformService 保持一致。 */
    private val readerPlatformChannel = "io.legado.flutter/reader_platform"

    /** 首次进入阅读器前窗口是否已经由其他功能设置常亮；退出时据此恢复。 */
    private var originalKeepScreenOn: Boolean? = null

    /** 注册 M08 阅读器最小平台通道。 */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
