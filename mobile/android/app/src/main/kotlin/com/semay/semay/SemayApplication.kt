package com.semay.semay

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build

// The app's notification channels are created HERE, not in MainActivity,
// because the FCM SDK draws a backgrounded app's notification from inside
// FirebaseMessagingService: that starts the process — so Application.onCreate
// runs — but never starts MainActivity. Straight after a Play Store update
// the app has usually not been opened yet, and a chat push naming a channel
// that does not exist (nor does the manifest default, which names the same
// id) is posted by the SDK on its own auto-created
// "fcm_fallback_notification_channel" ("Miscellaneous", IMPORTANCE_DEFAULT):
// no heads-up banner, no user-silenceable category of its own, and a stray
// one left in the app's notification settings for good. Creating
// them from the Application means the channel exists before the very first
// notification of the new version is drawn, whatever started the process.
//
// Registered as android:name=".SemayApplication" in AndroidManifest.xml,
// replacing Flutter's ${applicationName} placeholder, which is literally
// "android.app.Application" (BaseApplicationNameHandler.kt in the Flutter
// Gradle plugin) — hence the base class here. If this app ever needs
// multidex (it is minSdk 24, so it does not), that placeholder is how the
// tool injects FlutterMultiDexApplication, and this class would have to
// extend it instead.
class SemayApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        createNotificationChannels(this)
    }
}

// Android 8+ routes every notification through a channel, and the channel's
// importance and sound — fixed at creation, user-adjustable afterwards —
// decide whether it pops as a heads-up banner and what it plays. Without one
// of our own, FCM used its auto-created "Miscellaneous" channel at default
// importance: no banner, no sound, which is why new messages went unnoticed.
// The ids must match what the server sends as android.notification.channelId
// — CHAT_PUSH_CHANNEL in server/src/chats/service.ts, BROADCAST_PUSH_CHANNEL
// in server/src/notifications/service.ts, ORDER_PUSH_CHANNEL in
// server/src/orders/service.ts — and what notification_service.dart posts a
// foreground push on; the chat one is also the manifest's
// default_notification_channel_id.
//
// No setSound anywhere below: all three channels take the PHONE'S DEFAULT
// notification sound, which is what the owner asked for ("normal notification
// with the phone's default sound"). A channel created without setSound gets
// Settings.System.DEFAULT_NOTIFICATION_URI, not silence.
//
// "chat_messages_v2" is a retired id and is deleted on every start. An
// intermediate build gave chat messages a bundled sound, and because a
// channel's sound is fixed at creation (setSound on an existing channel is
// ignored) that needed a new id; only the owner's own test handsets ever
// created it, and deleting it keeps a stale, unused category out of their
// notification settings. Chat is back on the original "chat_messages", which
// every device running the last released build already has — with the default
// sound — so there is nothing to migrate and no immutable-sound trap. On a
// test handset where that intermediate build had DELETED "chat_messages",
// creating it again restores the channel's original settings, which were the
// default sound: the right outcome either way.
//
// Announcements and order notices get channels of their own so a user can
// silence either without silencing chats.
// Creating an existing channel is a no-op (only its name and description are
// updated, which is what makes the localized strings below correct after a
// language change), and deleting an absent one is a no-op too, so this is safe
// on every process start.
internal fun createNotificationChannels(app: Application) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val manager = app.getSystemService(NotificationManager::class.java) ?: return
    manager.deleteNotificationChannel(RETIRED_CHAT_CHANNEL_ID)
    manager.createNotificationChannel(
        NotificationChannel(
            CHAT_CHANNEL_ID,
            // Names and descriptions are user-visible (Settings -> Apps ->
            // SeMay -> Notifications), and the product ships Turkmen and
            // Russian only — see lib/core/l10n.dart. res/values is Turkmen,
            // res/values-ru is Russian; Android picks by device locale.
            app.getString(R.string.channel_chat_name),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = app.getString(R.string.channel_chat_description)
            enableVibration(true)
            setShowBadge(true)
        }
    )
    manager.createNotificationChannel(
        NotificationChannel(
            ANNOUNCEMENTS_CHANNEL_ID,
            app.getString(R.string.channel_announcements_name),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = app.getString(R.string.channel_announcements_description)
            enableVibration(true)
            setShowBadge(true)
        }
    )
    manager.createNotificationChannel(
        NotificationChannel(
            ORDERS_CHANNEL_ID,
            app.getString(R.string.channel_orders_name),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = app.getString(R.string.channel_orders_description)
            enableVibration(true)
            setShowBadge(true)
        }
    )
}

internal const val CHAT_CHANNEL_ID = "chat_messages"
// Only ever created by intermediate local test builds (the bundled message
// sound); deleted above so it does not linger in those handsets' notification
// settings. Nothing creates it any more — do not reuse the id.
internal const val RETIRED_CHAT_CHANNEL_ID = "chat_messages_v2"
internal const val ANNOUNCEMENTS_CHANNEL_ID = "announcements"
internal const val ORDERS_CHANNEL_ID = "orders"
