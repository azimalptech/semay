package com.semay.semay

import io.flutter.embedding.android.FlutterActivity

// Notification channels are NOT created here: the FCM SDK can draw a chat
// notification without this activity ever starting (a backgrounded or freshly
// updated app), so they are created from SemayApplication.onCreate — see
// SemayApplication.kt for the ids and why none of them sets a sound.
class MainActivity : FlutterActivity()
