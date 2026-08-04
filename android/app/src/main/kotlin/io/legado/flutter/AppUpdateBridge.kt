package io.legado.flutter

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android 服务端 APK 的单任务下载、断点续传、摘要校验和系统安装器桥。
 *
 * 下载地址和本地路径不会回传 Dart 或写入日志；Android 包安装器仍会执行签名校验。
 */
class AppUpdateBridge(
    private val activity: MainActivity,
    flutterEngine: FlutterEngine,
) {
    /** 与 Dart `AndroidApkUpdateService` 共用的窄平台通道。 */
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "io.legado.flutter/app_update",
    )

    /** APK 网络和文件操作固定在单线程执行，禁止两个升级任务覆盖同一临时文件。 */
    private val executor = Executors.newSingleThreadExecutor()

    /** 所有 Flutter 回调和安装 Intent 都切回 Android 主线程。 */
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 原子单飞行标记，处理 Dart 快速重复点击。 */
    private val isRunning = AtomicBoolean(false)

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "downloadAndInstall") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            /** 服务端返回并经 Dart 校验的 APK 地址。 */
            val rawUrl = call.argument<String>("url")?.trim()
            /** 服务端返回并经 Dart 校验的小写 SHA-256。 */
            val expectedSha256 = call.argument<String>("sha256")?.trim()?.lowercase()
            /** 服务端声明的不可变 APK 精确字节数。 */
            val expectedByteSize = call.argument<Number>("byteSize")?.toLong()
            /** 仅用于形成稳定临时文件名的版本名称。 */
            val versionName = call.argument<String>("versionName")?.trim()
            if (
                rawUrl.isNullOrEmpty() ||
                expectedSha256?.matches(Regex("^[0-9a-f]{64}$")) != true ||
                expectedByteSize == null ||
                expectedByteSize <= 0L ||
                versionName.isNullOrEmpty() ||
                !isSupportedDownloadUrl(rawUrl)
            ) {
                result.error("INVALID_APK_UPDATE", "APK 更新信息无效，请稍后重试", null)
                return@setMethodCallHandler
            }
            if (!isRunning.compareAndSet(false, true)) {
                result.success(null)
                return@setMethodCallHandler
            }
            result.success(null)
            executor.execute {
                runUpdate(
                    rawUrl = rawUrl.orEmpty(),
                    expectedSha256 = expectedSha256.orEmpty(),
                    expectedByteSize = expectedByteSize ?: 0L,
                    versionName = versionName.orEmpty(),
                )
            }
        }
    }

    /** 校验 URL 只允许带主机的 HTTP/HTTPS，重定向后的协议继续交由连接层限制。 */
    private fun isSupportedDownloadUrl(rawUrl: String): Boolean {
        return try {
            /** 仅用于结构校验的服务端 URL。 */
            val uri = Uri.parse(rawUrl)
            val scheme = uri.scheme?.lowercase()
            (scheme == "http" || scheme == "https") && !uri.host.isNullOrBlank()
        } catch (_: IllegalArgumentException) {
            false
        }
    }

    /** 在单线程完成缓存命中校验、续传和安装器交接。 */
    private fun runUpdate(
        rawUrl: String,
        expectedSha256: String,
        expectedByteSize: Long,
        versionName: String,
    ) {
        try {
            /** 版本和摘要共同形成文件身份，防止同版本制品被静默替换后复用旧文件。 */
            val safeVersion = versionName.replace(Regex("[^A-Za-z0-9._-]"), "_")
            /** 只位于应用 cache 的更新目录，卸载、清数据或系统回收时可移除。 */
            val updateDirectory = File(activity.cacheDir, "app_updates")
            if (!updateDirectory.exists() && !updateDirectory.mkdirs()) {
                throw AppUpdateException("无法创建 APK 临时目录")
            }
            /** 未完成下载保留 `.part`，下一次点击按现有长度发起 Range。 */
            val partialFile = File(updateDirectory, "pagenest-$safeVersion-${expectedSha256.take(12)}.apk.part")
            /** 校验完成的 APK 使用独立扩展名，FileProvider 只授权该文件给安装器。 */
            val completedFile = File(updateDirectory, "pagenest-$safeVersion-${expectedSha256.take(12)}.apk")

            if (!isVerifiedFile(completedFile, expectedByteSize, expectedSha256)) {
                if (completedFile.exists()) {
                    completedFile.delete()
                }
                downloadFile(
                    rawUrl = rawUrl,
                    target = partialFile,
                    expectedByteSize = expectedByteSize,
                    allowResume = true,
                )
                emitState(
                    stage = "verifying",
                    downloadedBytes = partialFile.length(),
                    totalBytes = expectedByteSize,
                    message = "正在校验安装包…",
                )
                if (!isVerifiedFile(partialFile, expectedByteSize, expectedSha256)) {
                    partialFile.delete()
                    throw AppUpdateException("安装包校验失败，请重新下载")
                }
                if (completedFile.exists()) {
                    completedFile.delete()
                }
                if (!partialFile.renameTo(completedFile)) {
                    throw AppUpdateException("无法准备安装包，请稍后重试")
                }
            }
            openPackageInstaller(completedFile, expectedByteSize)
        } catch (error: AppUpdateException) {
            emitState(stage = "failed", message = error.safeMessage)
        } catch (_: Exception) {
            emitState(stage = "failed", message = "APK 下载失败，请检查网络后重试")
        } finally {
            isRunning.set(false)
        }
    }

    /** 使用标准 Range 续传；服务端忽略 Range 返回 200 时安全地从头覆盖。 */
    private fun downloadFile(
        rawUrl: String,
        target: File,
        expectedByteSize: Long,
        allowResume: Boolean,
    ) {
        if (target.length() > expectedByteSize) {
            target.delete()
        }
        /** 本次 Range 起点；不允许续传时固定从零开始。 */
        val existingBytes = if (allowResume && target.exists()) target.length() else 0L
        var connection: HttpURLConnection? = null
        try {
            /** 使用系统网络栈流式下载，不把完整 APK 放进 Dart 或 JVM 内存。 */
            connection = URL(rawUrl).openConnection() as? HttpURLConnection
                ?: throw AppUpdateException("APK 下载地址不可用")
            connection.instanceFollowRedirects = true
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("Accept", "application/vnd.android.package-archive, application/octet-stream")
            if (existingBytes > 0L) {
                connection.setRequestProperty("Range", "bytes=$existingBytes-")
            }
            connection.connect()
            /** 完整响应从头覆盖；206 必须与本地现有字节精确衔接。 */
            val responseCode = connection.responseCode
            if (responseCode == 416 && existingBytes > 0L) {
                target.delete()
                connection.disconnect()
                downloadFile(rawUrl, target, expectedByteSize, allowResume = false)
                return
            }
            val append = responseCode == HttpURLConnection.HTTP_PARTIAL
            if (responseCode != HttpURLConnection.HTTP_OK && !append) {
                throw AppUpdateException("服务器暂时无法提供安装包")
            }
            if (append) {
                val contentRange = connection.getHeaderField("Content-Range")?.lowercase()
                if (contentRange?.startsWith("bytes $existingBytes-") != true) {
                    throw AppUpdateException("服务器续传响应无效，请重新下载")
                }
            }
            /** 本轮实际开始写入前的字节数。 */
            var downloadedBytes = if (append) existingBytes else 0L
            emitState(
                stage = "downloading",
                downloadedBytes = downloadedBytes,
                totalBytes = expectedByteSize,
                message = if (append) "正在继续下载 APK…" else "正在下载 APK…",
            )
            connection.inputStream.use { input ->
                FileOutputStream(target, append).use { output ->
                    /** 固定 64 KiB 缓冲，避免大 APK 产生与文件大小相关的内存占用。 */
                    val buffer = ByteArray(64 * 1024)
                    var lastProgressAt = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) {
                            break
                        }
                        output.write(buffer, 0, count)
                        downloadedBytes += count
                        if (downloadedBytes > expectedByteSize) {
                            throw AppUpdateException("安装包大小超过服务器约定")
                        }
                        val now = System.currentTimeMillis()
                        if (now - lastProgressAt >= 250L) {
                            lastProgressAt = now
                            emitState(
                                stage = "downloading",
                                downloadedBytes = downloadedBytes,
                                totalBytes = expectedByteSize,
                                message = "正在下载 APK…",
                            )
                        }
                    }
                    output.fd.sync()
                }
            }
            if (downloadedBytes != expectedByteSize) {
                throw AppUpdateException("安装包下载不完整，可再次点击继续")
            }
        } finally {
            connection?.disconnect()
        }
    }

    /** 先核对精确字节数，再流式计算 SHA-256，避免读取损坏或超大文件到内存。 */
    private fun isVerifiedFile(file: File, expectedByteSize: Long, expectedSha256: String): Boolean {
        if (!file.isFile || file.length() != expectedByteSize) {
            return false
        }
        /** Android 系统提供的 SHA-256 摘要器。 */
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) {
                    break
                }
                digest.update(buffer, 0, count)
            }
        }
        /** 固定两位小写十六进制，与服务端响应约定一致。 */
        val actualSha256 = digest.digest().joinToString("") { byte -> "%02x".format(byte) }
        return actualSha256 == expectedSha256
    }

    /** 缺少未知来源授权时先打开系统设置；授权后用户再次点击即可复用已校验 APK。 */
    private fun openPackageInstaller(apkFile: File, totalBytes: Long) {
        mainHandler.post {
            if (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !activity.packageManager.canRequestPackageInstalls()
            ) {
                emitState(
                    stage = "permissionRequired",
                    downloadedBytes = totalBytes,
                    totalBytes = totalBytes,
                    message = "请允许安装未知应用，返回后再次点击立即更新",
                )
                try {
                    activity.startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}"),
                        ),
                    )
                } catch (_: ActivityNotFoundException) {
                    emitState(stage = "failed", message = "无法打开安装权限设置")
                }
                return@post
            }
            try {
                /** FileProvider 只对本次安装 Intent 临时授予 APK 读取权限。 */
                val apkUri = FileProvider.getUriForFile(
                    activity,
                    "${activity.packageName}.app_update_files",
                    apkFile,
                )
                emitState(
                    stage = "installing",
                    downloadedBytes = totalBytes,
                    totalBytes = totalBytes,
                    message = "正在打开系统安装器…",
                )
                activity.startActivity(
                    Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(apkUri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    },
                )
            } catch (_: ActivityNotFoundException) {
                emitState(stage = "failed", message = "系统中没有可用的 APK 安装器")
            } catch (_: IllegalArgumentException) {
                emitState(stage = "failed", message = "无法授权读取安装包")
            }
        }
    }

    /** 将不含 URL、路径和摘要的状态发布给 Flutter 界面。 */
    private fun emitState(
        stage: String,
        downloadedBytes: Long = 0L,
        totalBytes: Long? = null,
        message: String? = null,
    ) {
        mainHandler.post {
            channel.invokeMethod(
                "updateState",
                mapOf(
                    "stage" to stage,
                    "downloadedBytes" to downloadedBytes,
                    "totalBytes" to totalBytes,
                    "message" to message,
                ),
            )
        }
    }

    /** Activity 销毁时停止接收新任务并中断尚未开始的排队工作。 */
    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }
}

/** 仅携带允许展示给用户的受控 APK 更新错误。 */
private class AppUpdateException(val safeMessage: String) : Exception(safeMessage)
