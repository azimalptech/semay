package com.semay.smssender

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.semay.smssender.databinding.ActivityMainBinding

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var prefs: Prefs

    private val requestPermissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            refreshSims()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        prefs = Prefs(this)
        binding.relayUrl.setText(prefs.relayUrl)
        binding.token.setText(prefs.token)
        binding.sendDelay.setText(prefs.sendDelayMs.toString())

        binding.startButton.setOnClickListener { saveAndStart() }
        binding.stopButton.setOnClickListener {
            SenderService.stop(this)
            binding.statusText.text = getString(R.string.status_idle)
        }
        binding.permissionsButton.setOnClickListener { requestNeededPermissions() }
        binding.batteryButton.setOnClickListener { requestBatteryExemption() }
    }

    private val statusReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: Intent?) {
            intent?.getStringExtra(SenderService.EXTRA_STATUS)?.let {
                binding.statusText.text = it
            }
        }
    }

    override fun onResume() {
        super.onResume()
        refreshSims()
        // Show the truth on arrival, then track changes. Reading the last known
        // status first matters: without it the screen sits on whatever it said
        // when it was last open, which is exactly the misleading-state problem
        // this app is supposed to solve rather than reproduce.
        binding.statusText.text = SenderService.lastStatus
        androidx.core.content.ContextCompat.registerReceiver(
            this,
            statusReceiver,
            android.content.IntentFilter(SenderService.ACTION_STATUS),
            androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    override fun onPause() {
        super.onPause()
        runCatching { unregisterReceiver(statusReceiver) }
    }

    private fun saveAndStart() {
        val url = binding.relayUrl.text.toString().trim()
        val token = binding.token.text.toString().trim()
        if (url.isBlank() || token.isBlank()) {
            toast("Enter the relay URL and device token first")
            return
        }
        prefs.relayUrl = url
        prefs.token = token

        // Blank or unparseable falls back to the default rather than 0: an
        // accidental empty field should not silently turn off pacing and get
        // the SIM blocked.
        val typed = binding.sendDelay.text.toString().trim().toLongOrNull()
        if (typed == null && binding.sendDelay.text.isNotBlank()) {
            toast("Delay must be a number in milliseconds")
            return
        }
        prefs.sendDelayMs = typed ?: Prefs.DEFAULT_DELAY_MS
        binding.sendDelay.setText(prefs.sendDelayMs.toString())

        if (!SmsSender(this).hasPermission() || !SimEnumerator.hasPermission(this)) {
            toast("Grant SMS and phone permissions first")
            requestNeededPermissions()
            return
        }

        SenderService.start(this)
        binding.statusText.text = "Starting…"
        // The socket endpoint is derived from the base URL, so show what we
        // actually resolved — a wrong path here is otherwise invisible until
        // nothing ever connects.
        toast("Connecting to ${RelayClient.toWebSocketUrl(url)}")
    }

    private fun requestNeededPermissions() {
        val wanted = mutableListOf(
            Manifest.permission.SEND_SMS,
            Manifest.permission.READ_PHONE_STATE,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Without this the foreground-service notification is suppressed,
            // and an operator cannot tell a running sender from a dead one.
            wanted += Manifest.permission.POST_NOTIFICATIONS
        }
        requestPermissions.launch(wanted.toTypedArray())
    }

    private fun requestBatteryExemption() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            toast("Not needed on this Android version")
            return
        }
        val pm = getSystemService(PowerManager::class.java)
        if (pm.isIgnoringBatteryOptimizations(packageName)) {
            toast("Already exempt from battery optimisation")
            return
        }
        runCatching {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                )
            )
        }.onFailure {
            // Some OEM builds hide the direct intent; fall back to the list.
            runCatching {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }.onFailure { toast("Open Settings > Battery and exempt this app manually") }
        }
    }

    private fun refreshSims() {
        if (!SimEnumerator.hasPermission(this)) {
            binding.simText.text = getString(R.string.sims_unknown)
            return
        }
        val sims = SimEnumerator.list(this)
        binding.simText.text = if (sims.isEmpty()) {
            "No active SIM detected"
        } else {
            sims.joinToString("\n") { sim ->
                "slot ${sim.slotIndex} · sub ${sim.subscriptionId} · " +
                    sim.carrierName.ifBlank { "unknown carrier" }
            }
        }
    }

    private fun toast(message: String) =
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
}
