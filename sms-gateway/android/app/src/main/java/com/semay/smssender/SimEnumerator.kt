package com.semay.smssender

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.telephony.SubscriptionInfo
import android.telephony.SubscriptionManager
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject

data class Sim(
    val slotIndex: Int,
    val subscriptionId: Int,
    val carrierName: String,
    val phoneNumber: String,
)

/**
 * Lists the SIMs currently usable for sending.
 *
 * Deliberately uses SubscriptionManager's ACTIVE list rather than anything
 * historical: a handset remembers every SIM it has ever seen, and dumping that
 * history would register slots that no longer exist, so dispatch would route
 * messages to a SIM that cannot send them.
 */
object SimEnumerator {

    fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) ==
            PackageManager.PERMISSION_GRANTED

    fun list(context: Context): List<Sim> {
        if (!hasPermission(context)) return emptyList()
        val sm = context.getSystemService(SubscriptionManager::class.java) ?: return emptyList()

        val active: List<SubscriptionInfo> = try {
            sm.activeSubscriptionInfoList ?: emptyList()
        } catch (_: SecurityException) {
            // Some OEM builds throw despite the permission check above.
            emptyList()
        }

        return active.map { info ->
            Sim(
                slotIndex = info.simSlotIndex,
                subscriptionId = info.subscriptionId,
                carrierName = info.carrierName?.toString().orEmpty(),
                // Frequently blank on Turkmen SIMs — the carrier simply does not
                // publish the MSISDN. Never used for routing, only display.
                phoneNumber = runCatching { info.number.orEmpty() }.getOrDefault(""),
            )
        }.sortedBy { it.slotIndex }
    }

    fun toJson(sims: List<Sim>): JSONArray {
        val arr = JSONArray()
        sims.forEach { sim ->
            arr.put(
                JSONObject().apply {
                    put("slotIndex", sim.slotIndex)
                    put("subscriptionId", sim.subscriptionId)
                    put("carrierName", sim.carrierName)
                    put("phoneNumber", sim.phoneNumber)
                }
            )
        }
        return arr
    }
}
