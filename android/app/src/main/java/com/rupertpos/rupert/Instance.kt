package com.rupertpos.rupert

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit

/**
 * Where the app is pointed.
 *
 * Everyone starts on the control plane (pos.rupertpos.com, BuildConfig.CONTROL_PLANE_URL): sign
 * in, sign up and pick a workspace there. A customer with an isolated workspace moves to that
 * instance after the handoff (WorkspaceHandoff), and the tabs follow. A self-hosted Rupert can be
 * chosen instead in App settings → Rupert server (ServerActivity); it then plays the control
 * plane's part.
 */
object Instance {
    private const val PREFERENCES = "rupert.instance"
    private const val SERVER_KEY = "serverOrigin"
    private const val CURRENT_KEY = "currentInstanceOrigin"

    private lateinit var preferences: SharedPreferences

    fun init(context: Context) {
        preferences = context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    }

    /** The control plane this build ships with. */
    val defaultControlPlane: String =
        InstanceAddress.originOf(BuildConfig.CONTROL_PLANE_URL) ?: "https://pos.rupertpos.com"

    /** The server people sign in on: the default, or the Rupert server picked in App settings. */
    val controlPlane: String
        get() = preferences.getString(SERVER_KEY, null)?.let(InstanceAddress::originOf) ?: defaultControlPlane

    val usesCustomServer: Boolean
        get() = preferences.contains(SERVER_KEY)

    /** The instance the tabs show. The control plane until a workspace handoff moves the app. */
    val current: String
        get() = preferences.getString(CURRENT_KEY, null)?.let(InstanceAddress::originOf) ?: controlPlane

    fun setCurrent(origin: String) {
        preferences.edit {
            if (origin == controlPlane) remove(CURRENT_KEY) else putString(CURRENT_KEY, origin)
        }
    }

    /** Points the app at another Rupert server (null: back to the default), starting over there. */
    fun setServer(origin: String?) {
        preferences.edit {
            if (origin == null || origin == defaultControlPlane) remove(SERVER_KEY) else putString(SERVER_KEY, origin)
            remove(CURRENT_KEY)
        }
    }

    /** A path on an instance (default: the current one), which may carry a query. */
    fun url(path: String, on: String = current): String = InstanceAddress.url(path, on)

    fun isRupert(url: String?): Boolean = InstanceAddress.isRupert(url, controlPlane, current)

    /** Origins Rupert's pages may talk to the app from (web message listeners, start scripts). */
    val trustedOriginRules: Set<String>
        get() = setOf("https://rupertpos.com", "https://*.rupertpos.com", controlPlane, current)

    val appVersion: String
        get() = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"
}
