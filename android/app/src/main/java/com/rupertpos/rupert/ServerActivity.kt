package com.rupertpos.rupert

import android.app.Activity
import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.button.MaterialButton
import com.google.android.material.progressindicator.CircularProgressIndicator
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import dev.hotwire.core.config.Hotwire
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Picks the Rupert server: pos.rupertpos.com by default, or a self-hosted Rupert (a public https
 * address, or a local one on this phone's network). The address is checked twice: its form
 * (InstanceAddress) and that it answers like Rupert (NativeHttp.probe) before the app moves there.
 */
class ServerActivity : AppCompatActivity() {
    private lateinit var field: TextInputLayout
    private lateinit var input: TextInputEditText
    private lateinit var connect: MaterialButton
    private lateinit var progress: CircularProgressIndicator

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_server)

        findViewById<MaterialToolbar>(R.id.toolbar).setNavigationOnClickListener { finish() }
        ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.server_scroll)) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            view.updatePadding(bottom = bars.bottom)
            insets
        }

        field = findViewById(R.id.server_field)
        input = findViewById(R.id.server_input)
        connect = findViewById(R.id.server_connect)
        progress = findViewById(R.id.server_progress)

        findViewById<TextView>(R.id.server_current).text =
            getString(R.string.server_current, InstanceAddress.hostOf(Instance.controlPlane))
        if (savedInstanceState == null && Instance.usesCustomServer) input.setText(Instance.controlPlane)

        input.setOnEditorActionListener { _, action, _ ->
            if (action == EditorInfo.IME_ACTION_GO) {
                check()
                true
            } else {
                false
            }
        }
        connect.setOnClickListener { check() }

        val reset = findViewById<MaterialButton>(R.id.server_reset)
        reset.text = getString(R.string.server_use_default, InstanceAddress.hostOf(Instance.defaultControlPlane))
        reset.isVisible = Instance.usesCustomServer
        reset.setOnClickListener { choose(null) }
    }

    private fun check() {
        field.error = null
        when (val result = InstanceAddress.parse(input.text?.toString().orEmpty())) {
            is InstanceAddress.Result.Invalid -> field.error = result.reason
            is InstanceAddress.Result.Valid -> probe(result.origin)
        }
    }

    private fun probe(origin: String) {
        setBusy(true)
        lifecycleScope.launch {
            val userAgent = Hotwire.config.userAgentWithWebViewDefault(this@ServerActivity)
            val probe = withContext(Dispatchers.IO) { NativeHttp.probe(origin, userAgent) }
            setBusy(false)
            when (probe) {
                NativeHttp.Probe.Rupert -> choose(origin)
                is NativeHttp.Probe.Problem -> field.error = probe.reason
            }
        }
    }

    private fun choose(origin: String?) {
        Instance.setServer(origin)
        setResult(Activity.RESULT_OK)
        finish()
    }

    private fun setBusy(busy: Boolean) {
        progress.visibility = if (busy) View.VISIBLE else View.GONE
        connect.isEnabled = !busy
        input.isEnabled = !busy
        if (busy) field.helperText = getString(R.string.server_checking) else field.helperText = getString(R.string.server_helper)
    }
}
