package com.semay.smssender

import android.content.Context

/** Relay URL and device token. Plain SharedPreferences: the token authorises
 * sending SMS from this handset, which anyone holding the unlocked phone can
 * already do from the Messages app, so encrypting it here would buy nothing. */
class Prefs(context: Context) {
    private val sp = context.getSharedPreferences("semay_sms_sender", Context.MODE_PRIVATE)

    var relayUrl: String
        get() = sp.getString(KEY_URL, "") ?: ""
        set(value) = sp.edit().putString(KEY_URL, value.trim()).apply()

    var token: String
        get() = sp.getString(KEY_TOKEN, "") ?: ""
        set(value) = sp.edit().putString(KEY_TOKEN, value.trim()).apply()

    /** Set once the operator has explicitly started the service, so BootReceiver
     * knows whether to bring it back up after a restart. Without this the app
     * would force itself on after every boot even when deliberately stopped. */
    var enabled: Boolean
        get() = sp.getBoolean(KEY_ENABLED, false)
        set(value) = sp.edit().putBoolean(KEY_ENABLED, value).apply()

    val isConfigured: Boolean
        get() = relayUrl.isNotBlank() && token.isNotBlank()

    companion object {
        private const val KEY_URL = "relay_url"
        private const val KEY_TOKEN = "device_token"
        private const val KEY_ENABLED = "enabled"
    }
}
