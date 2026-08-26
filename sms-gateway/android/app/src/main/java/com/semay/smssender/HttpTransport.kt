package com.semay.smssender

import android.content.Context
import android.util.Log
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * The fallback transport: plain HTTP long-polling.
 *
 * Exists because a WebSocket is not dependable enough to be the only path. An
 * nginx idle timeout, a carrier NAT, or Doze will sever it — sometimes without
 * either end noticing — and a gateway with one transport puts a single point of
 * failure between the server and every login in the system.
 *
 * This is not a degraded mode. A handset that only ever polls works completely;
 * it just spends a few more requests doing it. Claiming is atomic on the server
 * (the poll and the socket push share one lock), so both can be live at once
 * without a message ever going out twice.
 */
class HttpTransport(
    private val context: Context,
    private val prefs: Prefs,
    private val sendQueue: SendQueue,
    private val onStatus: (String) -> Unit,
) {

    private val client = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        // Must exceed the server's 25s hold or every idle poll would look like
        // a network failure.
        .readTimeout(40, TimeUnit.SECONDS)
        .build()

    private fun base(): String {
        var url = prefs.relayUrl.trim().trimEnd('/')
        if (!url.startsWith("http://") && !url.startsWith("https://")) url = "https://$url"
        return url
    }

    private fun post(path: String, body: JSONObject?): String? = try {
        val request = Request.Builder()
            .url("${base()}$path")
            .header("Authorization", "Bearer ${prefs.token}")
            .post((body?.toString() ?: "{}").toRequestBody(JSON))
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                Log.w(TAG, "$path -> HTTP ${response.code}")
                null
            } else {
                response.body?.string()
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "$path failed: ${e.message}")
        null
    }

    fun announceSims(): Boolean {
        val sims = SimEnumerator.list(context)
        val body = JSONObject().apply {
            put("type", "hello")
            put("sims", SimEnumerator.toJson(sims))
        }
        return post("/device/hello", body) != null
    }

    /**
     * One poll cycle: claim whatever the server has, send it, report each result.
     * Blocking — callers run it off the main thread.
     *
     * @return true if the server was reachable, regardless of whether it had work.
     */
    fun pollOnce(): Boolean {
        val raw = post("/device/poll", null) ?: return false
        val jobs = runCatching { JSONObject(raw).optJSONArray("jobs") }.getOrNull() ?: JSONArray()
        if (jobs.length() == 0) return true

        for (i in 0 until jobs.length()) {
            val job = jobs.optJSONObject(i) ?: continue
            val id = job.optString("id").ifBlank { continue }
            val subscriptionId = job.optInt("subscriptionId", -1)
            val text = job.optString("text")
            val numbers = job.optJSONArray("phoneNumbers")?.let { arr ->
                (0 until arr.length()).mapNotNull { arr.optString(it).takeIf(String::isNotBlank) }
            }.orEmpty()

            if (numbers.isEmpty() || subscriptionId < 0) {
                report(id, "Failed", "Malformed job", null)
                continue
            }

            onStatus("Queued ${numbers.size} message(s)… (polling)")
            // Same shared queue the socket path uses — see SendQueue.
            sendQueue.submit(
                SendQueue.Job(
                    id = id,
                    subscriptionId = subscriptionId,
                    phoneNumbers = numbers,
                    text = text,
                    onSent = { results ->
                        val allFailed = results.isNotEmpty() && results.all { !it.ok }
                        if (allFailed) {
                            report(id, "Failed", results.firstOrNull()?.error ?: "All recipients failed", results)
                            onStatus("Send failed (polling)")
                        } else {
                            report(id, "Sent", null, results)
                            onStatus("Sent (polling)")
                        }
                    },
                    onDelivered = { report(id, "Delivered", null, null) },
                )
            )
        }
        return true
    }

    private fun report(id: String, state: String, error: String?, results: List<RecipientResult>?) {
        val body = JSONObject().apply {
            put("type", "report")
            put("id", id)
            put("state", state)
            if (error != null) put("error", error)
            if (results != null) {
                put("recipients", JSONArray().apply {
                    results.forEach { r ->
                        put(JSONObject().apply {
                            put("phoneNumber", r.phoneNumber)
                            put("state", if (r.ok) state else "Failed")
                            if (r.error != null) put("error", r.error)
                        })
                    }
                })
            }
        }
        // Reporting runs on whatever thread the send callback fired on, which
        // is the main thread — so it must not block it.
        Thread { post("/device/report", body) }.start()
    }

    companion object {
        private const val TAG = "HttpTransport"
        private val JSON = "application/json; charset=utf-8".toMediaType()
    }
}
