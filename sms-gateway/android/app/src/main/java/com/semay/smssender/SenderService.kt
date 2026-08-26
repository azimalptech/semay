package com.semay.smssender

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Keeps the relay connection alive.
 *
 * A foreground service with a visible notification, because that is the only
 * thing Android will not quietly suspend. The failure this exists to prevent is
 * the one observed on the previous gateway: the process stays alive, the app
 * still says "online", and its socket has silently been dead for an hour — so
 * every login in that window fails with no sign of why.
 *
 * The wake lock is a partial one: the CPU stays available for the socket while
 * the screen is off. Battery cost on a permanently-charging handset is
 * irrelevant next to missing OTPs.
 */
class SenderService : Service() {

    private lateinit var prefs: Prefs
    private var client: RelayClient? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var status: String = "Starting…"

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification(status))

        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "semay:sms-sender")
            .apply { setReferenceCounted(false); acquire() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            prefs.enabled = false
            lastStatus = "Stopped"
            sendBroadcast(
                Intent(ACTION_STATUS).putExtra(EXTRA_STATUS, "Stopped").setPackage(packageName)
            )
            stopSelf()
            return START_NOT_STICKY
        }

        if (client == null) {
            client = RelayClient(this, prefs) { s ->
                status = s
                lastStatus = s
                updateNotification(s)
                // Broadcast to whatever Activity is showing. Package-scoped:
                // connection state is no other app's business.
                sendBroadcast(
                    Intent(ACTION_STATUS)
                        .putExtra(EXTRA_STATUS, s)
                        .setPackage(packageName)
                )
            }
        }
        client?.start()
        prefs.enabled = true

        // START_STICKY: if Android kills us under memory pressure, come back.
        // A sender that stays down until someone notices is the whole problem.
        return START_STICKY
    }

    override fun onDestroy() {
        client?.stop()
        client = null
        runCatching { wakeLock?.release() }
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "SMS sender",
            // LOW, not MIN: MIN lets some OEM launchers hide it entirely, and a
            // foreground service the operator cannot see is one they cannot
            // notice has stopped.
            NotificationManager.IMPORTANCE_LOW,
        ).apply { description = "Keeps the connection to the SeMay SMS relay open." }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("SeMay SMS sender")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(open)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(text))
    }

    companion object {
        const val ACTION_STOP = "com.semay.smssender.STOP"
        const val ACTION_STATUS = "com.semay.smssender.STATUS"
        const val EXTRA_STATUS = "status"
        private const val CHANNEL_ID = "sms_sender"
        private const val NOTIFICATION_ID = 1

        /** Last status published, so an Activity that starts (or returns to the
         * foreground) after the fact shows the truth immediately instead of
         * waiting for the next change. This app exists to make connection state
         * visible; a UI that says "Starting…" while the socket is live is the
         * same class of lie it was built to eliminate. */
        @Volatile
        var lastStatus: String = "Stopped"
            private set

        fun start(context: Context) {
            val intent = Intent(context, SenderService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(Intent(context, SenderService::class.java).setAction(ACTION_STOP))
        }
    }
}
