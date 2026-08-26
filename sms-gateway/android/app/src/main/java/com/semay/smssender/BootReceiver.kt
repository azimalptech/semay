package com.semay.smssender

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Brings the sender back after a reboot.
 *
 * A gateway handset that needs someone to remember to reopen an app after every
 * power cut is not a gateway. Only restarts if the operator had it running —
 * `prefs.enabled` — so a deliberately stopped sender stays stopped.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != "android.intent.action.QUICKBOOT_POWERON") {
            return
        }
        val prefs = Prefs(context)
        if (prefs.enabled && prefs.isConfigured) {
            SenderService.start(context)
        }
    }
}
