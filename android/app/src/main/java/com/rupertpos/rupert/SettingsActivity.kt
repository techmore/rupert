package com.rupertpos.rupert

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.materialswitch.MaterialSwitch

/**
 * App settings: a native screen behind the person button on each tab's first page. The app lock,
 * which Rupert server the app uses, help, privacy and deleting your account. Mirrors the iPhone
 * app's App settings sheet (ios/Sources/Rupert/AppSettings.swift).
 */
class SettingsActivity : AppCompatActivity() {
    private lateinit var lockSwitch: MaterialSwitch

    private val server = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            setResult(Activity.RESULT_OK, Intent().putExtra(EXTRA_SERVER_CHANGED, true))
            finish()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        findViewById<MaterialToolbar>(R.id.toolbar).setNavigationOnClickListener { finish() }
        ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.settings_scroll)) { view, insets ->
            view.updatePadding(bottom = insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom)
            insets
        }

        lockSwitch = findViewById(R.id.settings_lock)
        val lockAvailable = AppLock.isAvailable(this)
        lockSwitch.isChecked = AppLock.isEnabled
        lockSwitch.isEnabled = lockAvailable
        findViewById<TextView>(R.id.settings_lock_footer).setText(
            if (lockAvailable) R.string.settings_lock_footer else R.string.settings_lock_unavailable
        )
        lockSwitch.setOnCheckedChangeListener { _, on -> setLock(on) }

        findViewById<TextView>(R.id.settings_connected_to).text = InstanceAddress.hostOf(Instance.current)
        findViewById<View>(R.id.settings_server).setOnClickListener {
            server.launch(Intent(this, ServerActivity::class.java))
        }

        findViewById<View>(R.id.settings_support).setOnClickListener { open(Instance.url("/support", on = Instance.controlPlane)) }
        findViewById<View>(R.id.settings_report).setOnClickListener { open(Instance.url("/feedback_reports")) }
        findViewById<View>(R.id.settings_privacy).setOnClickListener { open(Instance.url("/privacy", on = Instance.controlPlane)) }
        findViewById<View>(R.id.settings_delete).setOnClickListener { open(Instance.url("/account/delete")) }
        findViewById<TextView>(R.id.settings_version).text = Instance.appVersion
    }

    private fun setLock(on: Boolean) {
        if (!on) {
            AppLock.isEnabled = false
            AppLock.protectRecents(this)
            return
        }
        if (AppLock.isEnabled) return
        // Turning it on proves the person can unlock, so nobody locks themselves out.
        AppLock.confirm(this, getString(R.string.lock_turn_on_prompt)) { ok ->
            AppLock.isEnabled = ok
            AppLock.protectRecents(this)
            if (!ok) lockSwitch.isChecked = false
        }
    }

    /** Opens a Rupert page in the current tab (this screen closes first). */
    private fun open(url: String) {
        setResult(Activity.RESULT_OK, Intent().putExtra(EXTRA_OPEN_URL, url))
        finish()
    }

    companion object {
        const val EXTRA_OPEN_URL = "com.rupertpos.rupert.OPEN_URL"
        const val EXTRA_SERVER_CHANGED = "com.rupertpos.rupert.SERVER_CHANGED"
    }
}
