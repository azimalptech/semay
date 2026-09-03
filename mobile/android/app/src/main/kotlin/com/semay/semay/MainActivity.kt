package com.semay.semay

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createChatNotificationChannel()
    }

    // Android 8+ routes every notification through a channel, and the channel's
    // importance — fixed at creation, user-adjustable afterwards — decides
    // whether it pops as a heads-up banner with sound or lands silently in the
    // shade. Without one of our own, FCM used its auto-created "Miscellaneous"
    // channel at default importance: no banner, no sound, which is why new
    // messages went unnoticed. The id must match CHAT_PUSH_CHANNEL in
    // server/src/chats/service.ts (sent as android.notification.channelId) and
    // the manifest's default_notification_channel_id. Creating an existing
    // channel is a no-op, so this is safe on every launch.
    private fun createChatNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHAT_CHANNEL_ID,
            "Messages",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "New chat messages"
            enableVibration(true)
            setShowBadge(true)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private companion object {
        const val CHAT_CHANNEL_ID = "chat_messages"
    }
}
