package com.semay.semay

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
    }

    // Android 8+ routes every notification through a channel, and the channel's
    // importance — fixed at creation, user-adjustable afterwards — decides
    // whether it pops as a heads-up banner with sound or lands silently in the
    // shade. Without one of our own, FCM used its auto-created "Miscellaneous"
    // channel at default importance: no banner, no sound, which is why new
    // messages went unnoticed. The ids must match what the server sends as
    // android.notification.channelId — CHAT_PUSH_CHANNEL in
    // server/src/chats/service.ts and BROADCAST_PUSH_CHANNEL in
    // server/src/notifications/service.ts — and what notification_service.dart
    // posts a foreground push on; the chat one is also the manifest's
    // default_notification_channel_id. Broadcasts get a channel of their own so
    // a user can silence announcements without silencing their chats. Creating
    // an existing channel is a no-op, so this is safe on every launch. Neither
    // sets a sound, which leaves the system default notification sound.
    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHAT_CHANNEL_ID,
                "Messages",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "New chat messages"
                enableVibration(true)
                setShowBadge(true)
            }
        )
        manager.createNotificationChannel(
            NotificationChannel(
                ANNOUNCEMENTS_CHANNEL_ID,
                "Announcements",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Announcements from SeMay"
                enableVibration(true)
                setShowBadge(true)
            }
        )
    }

    private companion object {
        const val CHAT_CHANNEL_ID = "chat_messages"
        const val ANNOUNCEMENTS_CHANNEL_ID = "announcements"
    }
}
