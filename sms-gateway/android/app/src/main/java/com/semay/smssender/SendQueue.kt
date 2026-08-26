package com.semay.smssender

import android.content.Context
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue

/**
 * Serialises every outgoing message through one thread and paces it.
 *
 * Both transports feed this, which is the point: the WebSocket path and the
 * polling path must not each keep their own idea of "last send", or a handset
 * running both would emit two messages back to back and undo the pacing that
 * keeps the SIM out of trouble.
 *
 * Single-threaded by design. SMS sending is not a throughput problem — it is
 * deliberately rate limited — so there is nothing to gain from concurrency and
 * a real risk in it.
 */
class SendQueue(
    context: Context,
    private val prefs: Prefs,
    private val onStatus: (String) -> Unit,
) {
    data class Job(
        val id: String,
        val subscriptionId: Int,
        val phoneNumbers: List<String>,
        val text: String,
        val onSent: (List<RecipientResult>) -> Unit,
        val onDelivered: () -> Unit,
    )

    private val sender = SmsSender(context)
    private val queue = LinkedBlockingQueue<Job>()
    private val worker = Executors.newSingleThreadExecutor()

    @Volatile
    private var lastSentAt = 0L

    @Volatile
    private var running = true

    init {
        worker.execute { drain() }
    }

    fun submit(job: Job) {
        queue.put(job)
    }

    fun pendingCount(): Int = queue.size

    fun shutdown() {
        running = false
        worker.shutdownNow()
    }

    private fun drain() {
        while (running) {
            val job = try {
                queue.take()
            } catch (_: InterruptedException) {
                return
            }

            // Wait out the remainder of the configured gap. Measured from the
            // last send rather than slept unconditionally, so a message that
            // arrives after a quiet period goes straight out — an OTP the user
            // is waiting on should not eat a delay that exists to throttle
            // bursts.
            val gap = prefs.sendDelayMs
            val since = System.currentTimeMillis() - lastSentAt
            if (lastSentAt > 0L && since < gap) {
                val wait = gap - since
                onStatus("Pacing ${wait / 1000}s before next send…")
                try {
                    Thread.sleep(wait)
                } catch (_: InterruptedException) {
                    return
                }
            }
            if (!running) return

            lastSentAt = System.currentTimeMillis()
            Log.i(TAG, "sending job ${job.id} via sub ${job.subscriptionId}")
            sender.send(
                jobId = job.id,
                subscriptionId = job.subscriptionId,
                phoneNumbers = job.phoneNumbers,
                text = job.text,
                onSent = job.onSent,
                onDelivered = job.onDelivered,
            )
        }
    }

    companion object {
        private const val TAG = "SendQueue"
    }
}
