package io.legado.flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 在 Flutter 串行下载队列工作时提升 Android 进程优先级并展示常驻进度通知。
 *
 * 章节领取、网络请求和数据库事实仍全部由 Dart `DownloadCoordinator` 管理；本服务只接收
 * 不含书名、URL、Cookie 和正文的公开计数，避免在 Kotlin 复制第二套下载状态机。
 */
class DownloadForegroundService : Service() {

    companion object {
        /** 前台通知渠道稳定标识。 */
        private const val channelId = "legado_flutter_downloads"

        /** 前台通知稳定编号。 */
        private const val notificationId = 3201

        /** 更新通知计数的 Intent 动作。 */
        private const val actionUpdate = "io.legado.flutter.DOWNLOAD_UPDATE"

        /** 构建启动或更新下载前台服务的显式 Intent。 */
        fun updateIntent(
            context: Context,
            waitingCount: Int,
            runningCount: Int,
            pausedCount: Int,
            successCount: Int,
            failedCount: Int,
        ): Intent {
            return Intent(context, DownloadForegroundService::class.java).apply {
                action = actionUpdate
                putExtra("waitingCount", waitingCount)
                putExtra("runningCount", runningCount)
                putExtra("pausedCount", pausedCount)
                putExtra("successCount", successCount)
                putExtra("failedCount", failedCount)
            }
        }
    }

    /** 前台服务不提供绑定接口。 */
    override fun onBind(intent: Intent?): IBinder? = null

    /** 创建通知渠道后等待 Dart 首次状态更新。 */
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    /** 使用最新公开计数更新常驻通知；进程被系统终止后由持久队列在下次启动续传。 */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        /** 当前等待任务数量。 */
        val waitingCount = intent?.getIntExtra("waitingCount", 0) ?: 0
        /** 当前运行任务数量。 */
        val runningCount = intent?.getIntExtra("runningCount", 0) ?: 0
        /** 当前暂停任务数量。 */
        val pausedCount = intent?.getIntExtra("pausedCount", 0) ?: 0
        /** 当前成功任务数量。 */
        val successCount = intent?.getIntExtra("successCount", 0) ?: 0
        /** 当前失败任务数量。 */
        val failedCount = intent?.getIntExtra("failedCount", 0) ?: 0
        startForeground(
            notificationId,
            buildNotification(
                waitingCount = waitingCount,
                runningCount = runningCount,
                pausedCount = pausedCount,
                successCount = successCount,
                failedCount = failedCount,
            ),
        )
        return START_NOT_STICKY
    }

    /** 建立低打扰下载通知渠道。 */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        /** 系统通知管理器。 */
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        /** 只在下载期间使用的低重要性渠道。 */
        val channel = NotificationChannel(
            channelId,
            "离线下载",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "显示离线章节串行下载进度"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    /** 构建不泄漏书籍或书源信息的下载汇总通知。 */
    private fun buildNotification(
        waitingCount: Int,
        runningCount: Int,
        pausedCount: Int,
        successCount: Int,
        failedCount: Int,
    ): Notification {
        /** 点击通知后回到现有 Flutter Activity。 */
        val activityIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        /** 通知点击使用的不可变 PendingIntent。 */
        val contentIntent = PendingIntent.getActivity(
            this,
            3201,
            activityIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        /** 用户可见的公开任务摘要。 */
        val summary = "下载中 $runningCount · 等待 $waitingCount · 暂停 $pausedCount · 完成 $successCount · 失败 $failedCount"
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("离线下载")
                .setContentText(summary)
                .setStyle(Notification.BigTextStyle().bigText(summary))
                .setContentIntent(contentIntent)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_PROGRESS)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("离线下载")
                .setContentText(summary)
                .setContentIntent(contentIntent)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .build()
        }
    }
}
