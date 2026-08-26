package com.semay.smssender

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import androidx.core.content.ContextCompat
import java.util.concurrent.atomic.AtomicBoolean

/** One recipient's result for a job. */
data class RecipientResult(val phoneNumber: String, val ok: Boolean, val error: String?)

/**
 * Sends a job's SMS through a specific SIM and reports back.
 *
 * The fiddly part is correlating Android's asynchronous send/delivery
 * broadcasts with the job that caused them. Intent equality IGNORES extras
 * (see Intent.filterEquals), so two jobs sharing one action would hand each
 * other's PendingIntents back and the wrong job would be reported sent. Every
 * job therefore gets its own action string, and each message part its own
 * requestCode.
 */
class SmsSender(private val context: Context) {

    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.SEND_SMS) ==
            PackageManager.PERMISSION_GRANTED

    private fun managerFor(subscriptionId: Int): SmsManager? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(SmsManager::class.java)
                ?.createForSubscriptionId(subscriptionId)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
        }
    } catch (_: Exception) {
        null
    }

    /**
     * @param onSent fired once, when every recipient has a terminal send result.
     * @param onDelivered fired at most once, if carrier receipts arrive for all
     *   recipients. Many carriers never send one, so this must never be the
     *   thing the relay waits on to consider a message successful.
     */
    fun send(
        jobId: String,
        subscriptionId: Int,
        phoneNumbers: List<String>,
        text: String,
        onSent: (List<RecipientResult>) -> Unit,
        onDelivered: () -> Unit,
    ) {
        if (!hasPermission()) {
            onSent(phoneNumbers.map { RecipientResult(it, false, "SEND_SMS permission not granted") })
            return
        }
        val sms = managerFor(subscriptionId)
        if (sms == null) {
            onSent(phoneNumbers.map { RecipientResult(it, false, "No SmsManager for subscription $subscriptionId") })
            return
        }

        val sentAction = "$ACTION_SENT:$jobId"
        val deliveredAction = "$ACTION_DELIVERED:$jobId"

        // Total parts across all recipients — a long body is split by the
        // carrier's 7-bit/UCS-2 limits, and each part reports separately.
        val partsPer = phoneNumbers.associateWith { sms.divideMessage(text) }
        val totalParts = partsPer.values.sumOf { it.size }

        val results = linkedMapOf<String, RecipientResult>()
        var sentSeen = 0
        var deliveredSeen = 0
        val finished = AtomicBoolean(false)
        val delivered = AtomicBoolean(false)

        lateinit var sentReceiver: BroadcastReceiver
        lateinit var deliveredReceiver: BroadcastReceiver
        val main = Handler(Looper.getMainLooper())

        fun unregister(receiver: BroadcastReceiver) {
            runCatching { context.unregisterReceiver(receiver) }
        }

        fun finish() {
            if (!finished.compareAndSet(false, true)) return
            unregister(sentReceiver)
            onSent(phoneNumbers.map { results[it] ?: RecipientResult(it, false, "No send result") })
        }

        sentReceiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                val phone = intent?.getStringExtra(EXTRA_PHONE) ?: return
                val ok = resultCode == Activity.RESULT_OK
                val existing = results[phone]
                // A multipart message reports per part; the recipient counts as
                // failed if ANY part failed, so never let a later OK overwrite
                // an earlier failure.
                if (existing == null || (existing.ok && !ok)) {
                    results[phone] = RecipientResult(phone, ok, if (ok) null else describe(resultCode))
                }
                sentSeen++
                if (sentSeen >= totalParts) finish()
            }
        }

        deliveredReceiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                deliveredSeen++
                if (deliveredSeen >= totalParts && delivered.compareAndSet(false, true)) {
                    unregister(deliveredReceiver)
                    onDelivered()
                }
            }
        }

        ContextCompat.registerReceiver(
            context, sentReceiver, IntentFilter(sentAction), ContextCompat.RECEIVER_NOT_EXPORTED
        )
        ContextCompat.registerReceiver(
            context, deliveredReceiver, IntentFilter(deliveredAction), ContextCompat.RECEIVER_NOT_EXPORTED
        )

        // Belt and braces. If the platform never broadcasts — it happens on
        // some OEM builds when the radio is wedged — this reports what we have
        // instead of leaking a receiver and leaving the relay to time the job
        // out with no explanation.
        main.postDelayed({
            finish()
            if (delivered.compareAndSet(false, true)) unregister(deliveredReceiver)
        }, SEND_TIMEOUT_MS)

        var requestCode = jobId.hashCode() and 0x00FFFFFF
        phoneNumbers.forEach { phone ->
            val parts = partsPer.getValue(phone)
            val sentIntents = ArrayList<PendingIntent>(parts.size)
            val deliveredIntents = ArrayList<PendingIntent>(parts.size)
            parts.indices.forEach { _ ->
                requestCode++
                sentIntents.add(
                    PendingIntent.getBroadcast(
                        context, requestCode,
                        Intent(sentAction).putExtra(EXTRA_PHONE, phone).setPackage(context.packageName),
                        pendingFlags(),
                    )
                )
                deliveredIntents.add(
                    PendingIntent.getBroadcast(
                        context, requestCode + 0x400000,
                        Intent(deliveredAction).putExtra(EXTRA_PHONE, phone).setPackage(context.packageName),
                        pendingFlags(),
                    )
                )
            }

            try {
                if (parts.size == 1) {
                    sms.sendTextMessage(phone, null, parts[0], sentIntents[0], deliveredIntents[0])
                } else {
                    sms.sendMultipartTextMessage(phone, null, parts, sentIntents, deliveredIntents)
                }
            } catch (e: Exception) {
                // Thrown synchronously for a malformed number or a radio that
                // is not up. No broadcast will ever arrive for these parts, so
                // account for them here or `finish()` would never be reached.
                results[phone] = RecipientResult(phone, false, e.message ?: "send threw")
                sentSeen += parts.size
                deliveredSeen += parts.size
                if (sentSeen >= totalParts) finish()
            }
        }
    }

    private fun pendingFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

    private fun describe(code: Int): String = when (code) {
        SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "Generic failure"
        SmsManager.RESULT_ERROR_NO_SERVICE -> "No service"
        SmsManager.RESULT_ERROR_NULL_PDU -> "Null PDU"
        SmsManager.RESULT_ERROR_RADIO_OFF -> "Radio off"
        else -> "Send failed (code $code)"
    }

    companion object {
        private const val ACTION_SENT = "com.semay.smssender.SMS_SENT"
        private const val ACTION_DELIVERED = "com.semay.smssender.SMS_DELIVERED"
        private const val EXTRA_PHONE = "phone"
        private const val SEND_TIMEOUT_MS = 60_000L
    }
}
