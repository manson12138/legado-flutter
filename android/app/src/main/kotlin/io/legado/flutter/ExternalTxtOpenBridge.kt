package io.legado.flutter

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 接收 Android 外部 TXT 打开请求，并把一次性 Uri 流式复制成 Dart 可立即读取的临时文件。
 *
 * 本桥只处理系统入口、文件元数据、受限复制和临时文件清理，不解析 TXT、不写书架，
 * 也不长期保存外部 Uri。Dart 消费临时文件后仍通过既有 LocalBookStorage 创建正式副本。
 */
internal class ExternalTxtOpenBridge(
    /** 当前 Flutter Activity，仅用于 ContentResolver、cacheDir 和主线程回调。 */
    private val activity: Activity,
    /** 当前 Activity 绑定的 FlutterEngine。 */
    flutterEngine: FlutterEngine,
) {

    companion object {
        /** 与 Dart LocalBookStorage.maxBookBytes 一致的单文件上限。 */
        private const val MAX_BOOK_BYTES = 1024L * 1024L * 1024L

        /** 单次进程会话允许等待的外部打开请求数，防止恶意 App 无界投递。 */
        private const val MAX_PENDING_REQUESTS = 4

        /** 超过一天仍未释放的临时副本可在下次桥初始化时清理。 */
        private const val STALE_FILE_AGE_MILLIS = 24L * 60L * 60L * 1000L

        /** 原生与 Dart 共用的平台通道名称。 */
        private const val CHANNEL_NAME = "io.legado.flutter/external_txt_open"

        /** 外部 TXT 临时副本专用目录名。 */
        private const val CACHE_DIRECTORY_NAME = "external_txt_open"
    }

    /** 与 Dart ExternalLocalBookOpenService 通信的方法通道。 */
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        CHANNEL_NAME,
    )

    /** 串行执行文件复制和清理，避免并发大文件复制放大磁盘与内存压力。 */
    private val fileExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    /** 尚未被 Dart 消费的外部 Uri 有界队列。 */
    private val pendingUris = ArrayDeque<Uri>()

    /** 已释放标志，避免 Activity 销毁后继续接受新任务。 */
    @Volatile
    private var disposed = false

    init {
        channel.setMethodCallHandler(::handleMethodCall)
        fileExecutor.execute(::deleteStaleFiles)
    }

    /**
     * 接收冷启动 Intent 或 singleTop Activity 的新 Intent。
     *
     * 无效 action、scheme 或重复 Uri 会被忽略；有效请求只入队，不在主线程读取文件。
     */
    fun handleIntent(intent: Intent?) {
        if (disposed || intent?.action != Intent.ACTION_VIEW) {
            return
        }
        /** 本次外部打开携带的文件 Uri。 */
        val uri = intent.data ?: return
        /** 只允许 Android 文件提供方或显式文件 Uri。 */
        val scheme = uri.scheme?.lowercase()
        if (scheme != "content" && scheme != "file") {
            return
        }
        /** Uri 文本只用于当前进程内去重，不写日志或持久化。 */
        val uriIdentity = uri.toString()
        synchronized(pendingUris) {
            if (pendingUris.any { it.toString() == uriIdentity }) {
                return
            }
            if (pendingUris.size >= MAX_PENDING_REQUESTS) {
                return
            }
            pendingUris.addLast(uri)
        }
        channel.invokeMethod("externalTxtOpenAvailable", null)
    }

    /** 处理 Dart 对下一请求消费或临时文件释放的调用。 */
    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "consumeNext" -> consumeNext(result)
            "releaseTemporary" -> releaseTemporary(call, result)
            else -> result.notImplemented()
        }
    }

    /** 从有界队列取出下一 Uri，并在文件线程完成校验和临时复制。 */
    private fun consumeNext(result: MethodChannel.Result) {
        if (disposed) {
            result.success(null)
            return
        }
        /** 当前需要复制的请求；取出后即使失败也不会形成无限重试。 */
        val uri = synchronized(pendingUris) {
            if (pendingUris.isEmpty()) null else pendingUris.removeFirst()
        }
        if (uri == null) {
            result.success(null)
            return
        }
        fileExecutor.execute {
            try {
                /** 返回给 Dart 的安全临时文件事实。 */
                val payload = copyToTemporaryFile(uri)
                postResult { result.success(payload) }
            } catch (error: ExternalTxtOpenException) {
                postResult {
                    result.error(error.code, error.message, null)
                }
            } catch (_: Exception) {
                postResult {
                    result.error(
                        "EXTERNAL_TXT_READ_FAILED",
                        "无法读取外部 TXT 文件，请确认文件仍然存在且允许访问",
                        null,
                    )
                }
            }
        }
    }

    /** 按一次性 token 异步删除已经导入或取消的外部临时副本。 */
    private fun releaseTemporary(call: MethodCall, result: MethodChannel.Result) {
        /** Dart 返回的随机文件 token，不接受绝对路径。 */
        val token = call.argument<String>("token")
        if (token.isNullOrBlank() || !isSafeToken(token)) {
            result.success(null)
            return
        }
        fileExecutor.execute {
            try {
                /** token 只能解析到专用 cache 目录的直接子文件。 */
                val file = File(cacheDirectory(), token)
                if (file.exists()) {
                    file.delete()
                }
            } finally {
                /** 清理失败仍结束 Dart 调用；过期文件会在下次启动继续兜底。 */
                postResult { result.success(null) }
            }
        }
    }

    /** 校验外部 Uri 并流式生成专用 cache 临时文件。 */
    private fun copyToTemporaryFile(uri: Uri): Map<String, Any> {
        /** 系统提供或从 Uri 回退得到的文件显示名。 */
        val displayName = resolveDisplayName(uri)
        if (!displayName.endsWith(".txt", ignoreCase = true)) {
            throw ExternalTxtOpenException(
                code = "EXTERNAL_TXT_UNSUPPORTED",
                message = "当前外部打开入口只支持 TXT 文件",
            )
        }
        /** 提供方声明的大小只用于提前拒绝，复制过程仍会独立计数。 */
        val declaredSize = resolveDeclaredSize(uri)
        if (declaredSize == 0L) {
            throw ExternalTxtOpenException(
                code = "EXTERNAL_TXT_EMPTY",
                message = "不能导入空 TXT 文件",
            )
        }
        if (declaredSize > MAX_BOOK_BYTES) {
            throw ExternalTxtOpenException(
                code = "EXTERNAL_TXT_TOO_LARGE",
                message = "单本书不能超过 1 GiB",
            )
        }
        /** 专用临时目录内的随机文件名，同时作为 Dart 释放文件的一次性 token。 */
        val token = "${UUID.randomUUID()}.txt"
        /** 复制尚未完成时使用的同目录文件，避免 Dart 读取半本书。 */
        val importingFile = File(cacheDirectory(), "$token.importing")
        /** 完整复制后才对 Dart 可见的临时文件。 */
        val completedFile = File(cacheDirectory(), token)
        try {
            openInputStream(uri).use { input ->
                FileOutputStream(importingFile).use { output ->
                    /** 固定大小复制缓冲区，不随 TXT 文件体积增长。 */
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    /** 已实际复制的字节数，用于识别空文件和谎报大小。 */
                    var copiedBytes = 0L
                    while (true) {
                        /** 当前批次读取字节数。 */
                        val readBytes = input.read(buffer)
                        if (readBytes < 0) {
                            break
                        }
                        copiedBytes += readBytes
                        if (copiedBytes > MAX_BOOK_BYTES) {
                            throw ExternalTxtOpenException(
                                code = "EXTERNAL_TXT_TOO_LARGE",
                                message = "单本书不能超过 1 GiB",
                            )
                        }
                        output.write(buffer, 0, readBytes)
                    }
                    output.flush()
                    output.fd.sync()
                    if (copiedBytes == 0L) {
                        throw ExternalTxtOpenException(
                            code = "EXTERNAL_TXT_EMPTY",
                            message = "不能导入空 TXT 文件",
                        )
                    }
                }
            }
            if (!importingFile.renameTo(completedFile)) {
                throw ExternalTxtOpenException(
                    code = "EXTERNAL_TXT_COPY_FAILED",
                    message = "复制外部 TXT 文件失败，请确认存储空间充足",
                )
            }
            /** 完成复制后的真实文件大小。 */
            val copiedSize = completedFile.length()
            return mapOf(
                "path" to completedFile.absolutePath,
                "name" to displayName,
                "size" to copiedSize,
                "token" to token,
            )
        } catch (error: Exception) {
            importingFile.delete()
            completedFile.delete()
            throw error
        }
    }

    /** 打开 content 或 file Uri 的输入流，调用方通过 use 保证关闭。 */
    private fun openInputStream(uri: Uri): InputStream {
        if (uri.scheme.equals("file", ignoreCase = true)) {
            /** file Uri 必须提供非空本地路径。 */
            val path = uri.path
                ?: throw ExternalTxtOpenException(
                    code = "EXTERNAL_TXT_READ_FAILED",
                    message = "外部 TXT 文件路径无效",
                )
            return FileInputStream(File(path))
        }
        return activity.contentResolver.openInputStream(uri)
            ?: throw ExternalTxtOpenException(
                code = "EXTERNAL_TXT_READ_FAILED",
                message = "无法读取外部 TXT 文件，请确认文件仍然存在且允许访问",
            )
    }

    /** 优先读取 OpenableColumns 显示名，再安全回退到 Uri 末段。 */
    private fun resolveDisplayName(uri: Uri): String {
        /** ContentResolver 返回的原始显示名。 */
        val queriedName = queryOpenableColumn(uri, OpenableColumns.DISPLAY_NAME) as? String
        /** Uri 末段只在提供方未返回显示名时使用。 */
        val fallbackName = uri.lastPathSegment?.substringAfterLast('/')
        /** 清理路径分隔符和控制字符后的安全显示名。 */
        val sanitized = sanitizeDisplayName(queriedName ?: fallbackName ?: "external.txt")
        return if (sanitized.isBlank()) "external.txt" else sanitized
    }

    /** 查询提供方声明大小；未知大小返回 -1 并交给复制过程计数。 */
    private fun resolveDeclaredSize(uri: Uri): Long {
        /** ContentResolver 可能返回 Long、Int 或空值。 */
        val queriedSize = queryOpenableColumn(uri, OpenableColumns.SIZE)
        return (queriedSize as? Number)?.toLong() ?: -1L
    }

    /** 查询单个 OpenableColumns 值，并在提供方异常时安全回退为空。 */
    private fun queryOpenableColumn(uri: Uri, columnName: String): Any? {
        if (!uri.scheme.equals("content", ignoreCase = true)) {
            return null
        }
        /** 查询结果只在当前方法内使用并立即关闭。 */
        val cursor: Cursor = try {
            activity.contentResolver.query(
                uri,
                arrayOf(columnName),
                null,
                null,
                null,
            )
        } catch (_: Exception) {
            null
        } ?: return null
        cursor.use {
            if (!it.moveToFirst()) {
                return null
            }
            /** 目标列索引；提供方缺列时安全回退。 */
            val columnIndex = it.getColumnIndex(columnName)
            if (columnIndex < 0 || it.isNull(columnIndex)) {
                return null
            }
            return if (columnName == OpenableColumns.SIZE) {
                it.getLong(columnIndex)
            } else {
                it.getString(columnIndex)
            }
        }
    }

    /** 去掉文件名中的路径字符和控制字符，并限制展示长度。 */
    private fun sanitizeDisplayName(rawName: String): String {
        /** 逐字符过滤后的文件名，避免外部名称影响临时路径或 UI。 */
        val filtered = rawName
            .map { character ->
                if (character.code < 32 || character in charArrayOf('\\', '/', ':', '*', '?', '"', '<', '>', '|')) {
                    '_'
                } else {
                    character
                }
            }
            .joinToString(separator = "")
        return filtered.take(180)
    }

    /** 返回并确保存在外部 TXT 专用 cache 目录。 */
    private fun cacheDirectory(): File {
        /** 所有一次性副本共同使用的应用私有目录。 */
        val directory = File(activity.cacheDir, CACHE_DIRECTORY_NAME)
        if (!directory.exists() && !directory.mkdirs()) {
            throw ExternalTxtOpenException(
                code = "EXTERNAL_TXT_COPY_FAILED",
                message = "无法准备外部 TXT 临时目录，请确认存储空间充足",
            )
        }
        return directory
    }

    /** 只允许桥自身生成的 UUID TXT token，阻止路径穿越删除。 */
    private fun isSafeToken(token: String): Boolean {
        if (!token.endsWith(".txt") || token.contains('/') || token.contains('\\')) {
            return false
        }
        /** 去掉扩展名后必须是标准 UUID 文本。 */
        val uuidText = token.removeSuffix(".txt")
        return try {
            UUID.fromString(uuidText)
            true
        } catch (_: IllegalArgumentException) {
            false
        }
    }

    /** 删除异常中断或进程被杀后遗留超过一天的专用临时文件。 */
    private fun deleteStaleFiles() {
        /** 清理判断使用的当前系统时间。 */
        val now = System.currentTimeMillis()
        /** 专用目录不存在时无需创建目录执行清理。 */
        val directory = File(activity.cacheDir, CACHE_DIRECTORY_NAME)
        /** 目录直接子文件快照，避免递归触及其他 cache。 */
        val files = directory.listFiles() ?: return
        files.forEach { file ->
            if (now - file.lastModified() >= STALE_FILE_AGE_MILLIS) {
                file.delete()
            }
        }
    }

    /** 把 MethodChannel 结果切回 Android 主线程。 */
    private fun postResult(callback: () -> Unit) {
        if (disposed) {
            return
        }
        activity.runOnUiThread {
            if (!disposed) {
                callback()
            }
        }
    }

    /** 解除通道并停止后台任务，不保留 Activity 引用或打开文件句柄。 */
    fun dispose() {
        if (disposed) {
            return
        }
        disposed = true
        channel.setMethodCallHandler(null)
        synchronized(pendingUris) {
            pendingUris.clear()
        }
        fileExecutor.shutdownNow()
    }
}

/** 原生外部 TXT 边界使用的受控错误，只向 Dart 暴露安全码和中文提示。 */
private class ExternalTxtOpenException(
    /** 稳定平台错误码。 */
    val code: String,
    /** 不包含路径、文件名或正文的安全提示。 */
    override val message: String,
) : Exception(message)
