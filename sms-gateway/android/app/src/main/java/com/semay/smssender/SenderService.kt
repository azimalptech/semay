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
 * Keeps the relay reachable, by whichever transport is working.
 *
 * A foreground service with a visible notification, because that is the only
 * thing Android will not quietly suspend. The failure this exists to prevent is
 * the one observed on the previous gateway: the process stays alive, the app
 * still says "online", and its socket has silently been dead for an hour — so
 * every login in that window fails with no sign of why.
 *
 * Two transports run under it. The WebSocket is preferred; whenever it is not
 * actually open, a polling loop takes over. Both feed one SendQueue, so pacing
 * holds regardless of which path a message arrived on.
 */
class SenderService : Service() {

    private lateinit var prefs: Prefs
    private var sendQueue: SendQueue? = null
    private var client: RelayClient? = null
    private var http: HttpTransport? = null
    private var pollThread: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null

    @Volatile
    private var running = false
    private var status: String = "Starting…"

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification(status))

        // Partial wake lock: CPU stays available for the socket while the screen
        // is off. Note this does NOT defeat Doze's network restrictions — only
        // the battery-optimisation exemption does that, which is why the app
        // nags for it.
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "semay:sms-sender")
            .apply { setReferenceCounted(false); acquire() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            prefs.enabled = false
            publish("Stopped")
            stopSelf()
            return START_NOT_STICKY
        }

        if (sendQueue == null) {
            sendQueue = SendQueue(this, prefs) { publish(it) }
        }
        val queue = sendQueue!!

        if (client == null) {
            client = RelayClient(this, prefs, queue) { publish(it) }
        }
        if (http == null) {
            http = HttpTransport(this, prefs, queue) { publish(it) }
        }
        client?.start()
        startPolling()
        prefs.enabled = true

        // START_STICKY: if Android kills us under memory pressure, come back. A
        // sender that stays down until someone notices is the whole problem.
        return START_STICKY
    }

    /**
     * The fallback loop. Idles cheaply while the socket is healthy and takes
     * over the moment it is not — which covers the cases a socket cannot: an
     * nginx idle timeout, a carrier NAT dropping the flow, or a relay restart.
     */
    private fun startPolling() {
        if (pollThread?.isAlive == true) return
        running = true
        pollThread = Thread {
            // Register SIMs over HTTP once at startup, so a handset whose socket
            // never comes up is still a usable sender rather than an unknown
            // device the relay will not route to.
            runCatching { http?.announceSims() }

            while (running) {
                try {
                    if (client?.isConnected() == true) {
                        // Socket is carrying the work; just re-check shortly.
                        Thread.sleep(SOCKET_HEALTHY_IDLE_MS)
                        continue
                    }
                    val reachable = http?.pollOnce() ?: false
                    if (!reachable) {
                        publish("Relay unreachable — retrying")
                        Thread.sleep(POLL_BACKOFF_MS)
                    }
                    // A successful poll returns immediately after the server's
                    // hold, so no sleep is needed here — the hold IS the pacing.
                } catch (_: InterruptedException) {
                    return@Thread
                } catch (_: Exception) {
                    runCatching { Thread.sleep(POLL_BACKOFF_MS) }
                }
            }
        }.apply { isDaemon = true; start() }
    }

    override fun onDestroy() {
        running = false
        pollThread?.interrupt()
        pollThread = null
        client?.stop()
        client = null
        http = null
        sendQueue?.shutdown()
        sendQueue = null
        runCatching { wakeLock?.release() }
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** Appends a battery-optimisation warning to every status while the
     * exemption is missing. It is the single most common reason a handset stops
     * receiving work overnight, and burying it in a settings screen nobody
     * revisits is how it goes unnoticed. */
    private fun publish(text: String) {
        val warned = if (isBatteryExempt()) text else "$text  ⚠ battery optimisation ON"
        status = warned
        lastStatus = warned
        updateNotification(warned)
        sendBroadcast(
            Intent(ACTION_STATUS).putExtra(EXTRA_STATUS, warned).setPackage(packageName)
        )
    }

    private fun isBatteryExempt(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
        } else true

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
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
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

        /** How often to re-check that the socket is still up, while it is. */
        private const val SOCKET_HEALTHY_IDLE_MS = 15_000L
        private const val POLL_BACKOFF_MS = 10_000L

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
