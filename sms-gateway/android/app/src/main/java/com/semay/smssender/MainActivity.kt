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

        binding.startButton.setOnClickListener { saveAndStart() }
        binding.stopButton.setOnClickListener {
            SenderService.stop(this)
            binding.statusText.text = getString(R.string.status_idle)
        }
        binding.permissionsButton.setOnClickListener { requestNeededPermissions() }
        binding.batteryButton.setOnClickListener { requestBatteryExemption() }
    }

    override fun onResume() {
        super.onResume()
        refreshSims()
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

        if (!SmsSender(this).hasPermission() || !SimEnumerator.hasPermission(this)) {
            toast("Grant SMS and phone permissions first")
            requestNeededPermissions()
            return
        }

        SenderService.start(this)
        binding.statusText.text = getString(R.string.status_idle).let { "Starting…" }
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
