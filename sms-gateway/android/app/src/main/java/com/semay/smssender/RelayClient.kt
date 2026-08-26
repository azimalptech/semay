package com.semay.smssender

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Holds the relay connection and turns `send` jobs into SMS.
 *
 * Reconnects with exponential backoff, with one deliberate exception: close
 * code 4401 means the relay rejected our token, and retrying a revoked
 * credential forever would just be a slow denial-of-service against our own
 * server. That case stops and surfaces to the operator instead.
 */
class RelayClient(
    private val context: Context,
    private val prefs: Prefs,
    private val onStatus: (String) -> Unit,
) {
    private val sender = SmsSender(context)
    private val main = Handler(Looper.getMainLooper())

    private val client = OkHttpClient.Builder()
        // OkHttp sends its own WebSocket pings. The relay pings too; between
        // them a carrier NAT cannot quietly drop the connection while both
        // sides still believe it is open.
        .pingInterval(25, TimeUnit.SECONDS)
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private var socket: WebSocket? = null
    private var running = false
    private var attempt = 0
    private var fatal = false

    fun start() {
        if (running) return
        running = true
        fatal = false
        attempt = 0
        connect()
    }

    fun stop() {
        running = false
        runCatching { socket?.close(1000, "stopped") }
        socket = null
    }

    fun isFatal(): Boolean = fatal

    private fun connect() {
        if (!running || fatal) return
        if (!prefs.isConfigured) {
            onStatus("Not configured")
            return
        }

        val url = toWebSocketUrl(prefs.relayUrl)
        onStatus("Connecting…")

        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer ${prefs.token}")
            .build()

        socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                attempt = 0
                val sims = SimEnumerator.list(context)
                if (sims.isEmpty()) {
                    // Announcing zero SIMs is legitimate — the permission may
                    // not be granted yet — but it means the relay will never
                    // route to us, so say so plainly rather than showing
                    // "Connected" and silently doing nothing.
                    onStatus("Connected — NO SIMs visible (grant phone permission)")
                } else {
                    onStatus("Connected — ${sims.size} SIM(s)")
                }
                webSocket.send(
                    JSONObject().apply {
                        put("type", "hello")
                        put("sims", SimEnumerator.toJson(sims))
                    }.toString()
                )
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleFrame(webSocket, text)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                handleDisconnect(code, reason)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                handleDisconnect(response?.code ?: -1, t.message ?: "connection failed")
            }
        })
    }

    private fun handleDisconnect(code: Int, reason: String) {
        socket = null
        if (code == 4401) {
            fatal = true
            running = false
            onStatus("Rejected: bad device token")
            return
        }
        if (!running) return

        attempt = (attempt + 1).coerceAtMost(6)
        val delay = (1000L shl (attempt - 1)).coerceAtMost(60_000L)
        onStatus("Disconnected ($reason) — retrying in ${delay / 1000}s")
        main.postDelayed({ connect() }, delay)
    }

    private fun handleFrame(webSocket: WebSocket, text: String) {
        val obj = runCatching { JSONObject(text) }.getOrNull() ?: return
        when (obj.optString("type")) {
            "ping" -> webSocket.send(JSONObject().put("type", "pong").toString())
            "send" -> handleSendJob(webSocket, obj)
        }
    }

    private fun handleSendJob(webSocket: WebSocket, obj: JSONObject) {
        val id = obj.optString("id").ifBlank { return }
        val subscriptionId = obj.optInt("subscriptionId", -1)
        val body = obj.optString("text")
        val numbers = obj.optJSONArray("phoneNumbers")?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.optString(it).takeIf(String::isNotBlank) }
        }.orEmpty()

        if (numbers.isEmpty() || subscriptionId < 0) {
            report(webSocket, id, "Failed", "Malformed job")
            return
        }

        Log.i(TAG, "job $id -> sub $subscriptionId, ${numbers.size} recipient(s)")
        onStatus("Sending ${numbers.size} message(s)…")

        sender.send(
            jobId = id,
            subscriptionId = subscriptionId,
            phoneNumbers = numbers,
            text = body,
            onSent = { results ->
                val failed = results.filter { !it.ok }
                if (failed.size == results.size) {
                    report(
                        webSocket, id, "Failed",
                        failed.firstOrNull()?.error ?: "All recipients failed",
                        results
                    )
                    onStatus("Send failed")
                } else {
                    report(webSocket, id, "Sent", null, results)
                    onStatus("Sent")
                }
            },
            onDelivered = {
                report(webSocket, id, "Delivered", null)
                onStatus("Delivered")
            },
        )
    }

    private fun report(
        webSocket: WebSocket,
        id: String,
        state: String,
        error: String?,
        results: List<RecipientResult>? = null,
    ) {
        val payload = JSONObject().apply {
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
        runCatching { webSocket.send(payload.toString()) }
    }

    companion object {
        private const val TAG = "RelayClient"

        /**
         * Accepts what an operator would naturally type — the same base URL
         * used for the API — and derives the socket endpoint from it, rather
         * than making them hand-write a `wss://…/device/ws` string and getting
         * it subtly wrong.
         */
        fun toWebSocketUrl(input: String): String {
            var url = input.trim().trimEnd('/')
            url = when {
                url.startsWith("https://") -> "wss://" + url.removePrefix("https://")
                url.startsWith("http://") -> "ws://" + url.removePrefix("http://")
                url.startsWith("wss://") || url.startsWith("ws://") -> url
                // Bare host: assume TLS, which is the only sane default for a
                // credential-bearing connection over the public internet.
                else -> "wss://$url"
            }
            return if (url.endsWith("/device/ws")) url else "$url/device/ws"
        }
    }
}
