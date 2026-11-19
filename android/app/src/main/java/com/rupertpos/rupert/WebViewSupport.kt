package com.rupertpos.rupert

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import android.webkit.WebView
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import dev.hotwire.core.turbo.webview.HotwireWebView
import org.json.JSONObject
import org.json.JSONTokener

/**
 * Rupert's web views: Hotwire's, plus what the app adds to every Rupert page.
 *
 * Pages talk to the app through two web message listeners, injected only into Rupert's own
 * origins and main frames (never into payment or other third-party iframes):
 * - `rupertScanner`: "Scan with camera" on inventory counts (BarcodeScanner).
 * - `rupertBanner`: the page's colours changed (BannerColors.WATCH_SCRIPT).
 */
@SuppressLint("ViewConstructor")
class RupertWebView(context: Context) : HotwireWebView(context, null) {
    /** Set by the page showing this web view (RupertWebFragment). */
    var onBannerChanged: ((BannerColors) -> Unit)? = null

    init {
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.setGeolocationEnabled(false)
        install()
    }

    private fun install() {
        // Needs a current Android System WebView; without these features the pages still work,
        // only without the camera scanner and live banner colours. (Robolectric tests have none.)
        try {
            installListeners()
        } catch (error: Exception) {
            Log.w("RupertWebView", "Web message features unavailable", error)
        }
    }

    private fun installListeners() {
        // Pages follow the appearance picked in Rupert's account menu; never let Chromium force-darken them.
        if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
            WebSettingsCompat.setAlgorithmicDarkeningAllowed(settings, false)
        }

        val origins = Instance.trustedOriginRules

        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(this, WebViewSupport.DIAGNOSTICS_SCRIPT, origins)
            WebViewCompat.addDocumentStartJavaScript(this, BannerColors.WATCH_SCRIPT, origins)
        }

        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(this, "rupertScanner", origins) { view, _, origin, isMainFrame, _ ->
                if (isMainFrame && Instance.isRupert(origin.toString())) {
                    BarcodeScanner.scan(view)
                }
            }
            WebViewCompat.addWebMessageListener(this, "rupertBanner", origins) { _, message, origin, isMainFrame, _ ->
                if (isMainFrame && Instance.isRupert(origin.toString())) {
                    BannerColors.parse(message.data)?.let { colors -> onBannerChanged?.invoke(colors) }
                }
            }
        }
    }
}

object WebViewSupport {
    /**
     * Records what went wrong while a page loaded (a module that failed to load, a script error),
     * so the app's error screen can say why Rupert's JavaScript did not start.
     */
    const val DIAGNOSTICS_SCRIPT = """(() => {
  const problems = [];
  addEventListener("error", (event) => {
    const target = event.target;
    if (target && target !== window && (target.src || target.href)) {
      problems.push("could not load " + (target.src || target.href));
    } else {
      problems.push(String(event.message) + " (" + (event.filename || "?") + ":" + event.lineno + ")");
    }
  }, true);
  addEventListener("unhandledrejection", (event) => {
    problems.push("unhandled: " + String(event.reason && (event.reason.message || event.reason)));
  });
  window.__rupertDiagnostics = () => JSON.stringify({
    turbo: typeof window.Turbo,
    hotwire: typeof window.TurboSession,
    ready: document.readyState,
    importmap: !!document.querySelector("script[type=importmap]"),
    modules: document.querySelectorAll("script[type=module]").length,
    problems: problems.slice(0, 12),
    page: location.pathname,
    agent: navigator.userAgent
  });
})();"""

    /** The diagnostics of the page in `webView`, as readable lines. */
    fun report(webView: WebView, done: (String) -> Unit) {
        webView.evaluateJavascript("window.__rupertDiagnostics ? window.__rupertDiagnostics() : null") { value ->
            done(format(value))
        }
    }

    fun format(value: String?): String {
        val info = runCatching {
            val text = JSONTokener(value.orEmpty()).nextValue() as? String
            text?.let(::JSONObject)
        }.getOrNull() ?: return "No page details (the page did not run any script)."

        val lines = mutableListOf(
            "Page: ${info.optString("page", "?")}",
            "Turbo: ${info.optString("turbo", "?")} · Hotwire: ${info.optString("hotwire", "?")} · ${info.optString("ready", "?")}",
            "Import map: ${info.opt("importmap") ?: "?"} · modules: ${info.opt("modules") ?: "?"}",
        )
        val problems = info.optJSONArray("problems")
        if (problems == null || problems.length() == 0) {
            lines += "No script errors recorded."
        } else {
            for (index in 0 until problems.length()) lines += problems.optString(index)
        }
        info.optString("agent").takeIf { it.isNotBlank() }?.let { lines += it }
        return lines.joinToString("\n")
    }
}
