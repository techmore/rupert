package com.rupertpos.rupert

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.res.ColorStateList
import android.net.Uri
import android.os.Bundle
import android.view.MenuItem
import android.view.View
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.widget.Button
import android.widget.TextView
import androidx.core.view.WindowCompat
import com.google.android.material.appbar.MaterialToolbar
import dev.hotwire.core.turbo.errors.LoadError
import dev.hotwire.core.turbo.errors.VisitError
import dev.hotwire.core.turbo.session.Session
import dev.hotwire.core.turbo.webview.HotwireWebChromeClient
import dev.hotwire.core.turbo.webview.HotwireWebView
import dev.hotwire.navigation.destinations.HotwireDestinationDeepLink
import dev.hotwire.navigation.fragments.HotwireWebFragment

/**
 * Rupert pages: Hotwire's web fragment, with the top bar in the page's banner colours, short
 * titles, the App settings button on each tab's first page and an error screen that says why.
 */
@HotwireDestinationDeepLink(uri = "hotwire://fragment/web")
class RupertWebFragment : HotwireWebFragment() {
    private var colors: BannerColors? = BannerColors.current

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        // Page titles end in " · Rupert" for browser tabs; the app's bar does not need it.
        fragmentViewModel.title.observe(viewLifecycleOwner) { title ->
            toolbarForNavigation()?.title = shortTitle(title)
        }
        if (navigator.isAtStartDestination() && !isModal) addSettingsButton()
        colors?.let(::apply)
    }

    override fun onResume() {
        super.onResume()
        colors?.let(::apply)
    }

    override fun onWebViewAttached(webView: HotwireWebView) {
        super.onWebViewAttached(webView)
        (webView as? RupertWebView)?.onBannerChanged = { apply(it) }
    }

    override fun onWebViewDetached(webView: HotwireWebView) {
        super.onWebViewDetached(webView)
        (webView as? RupertWebView)?.onBannerChanged = null
    }

    override fun onVisitRendered(location: String) {
        super.onVisitRendered(location)
        readBanner()
    }

    override fun onVisitCompleted(location: String, completedOffline: Boolean) {
        super.onVisitCompleted(location, completedOffline)
        readBanner()
        (activity as? MainActivity)?.visitCompleted(navigator, location)
    }

    override fun createWebChromeClient(): HotwireWebChromeClient = RupertWebChromeClient(navigator.session)

    /** Rupert's JavaScript did not start: say why, with the page's own diagnostics. */
    override fun createErrorView(error: VisitError): View {
        val view = layoutInflater.inflate(R.layout.view_error, null)
        val title = view.findViewById<TextView>(R.id.error_title)
        val message = view.findViewById<TextView>(R.id.error_message)
        val details = view.findViewById<TextView>(R.id.error_details)
        val copy = view.findViewById<Button>(R.id.error_copy)

        message.text = error.description()
        view.findViewById<Button>(R.id.error_retry).setOnClickListener { refresh(displayProgress = true) }

        if (error is LoadError) {
            title.setText(R.string.error_page_did_not_start)
            details.visibility = View.VISIBLE
            copy.visibility = View.VISIBLE
            navigator.session.webView.let { webView ->
                WebViewSupport.report(webView) { report ->
                    details.text = report
                    copy.setOnClickListener {
                        val clipboard = requireContext().getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newPlainText(getString(R.string.error_details_label), report))
                    }
                }
            }
        } else {
            title.setText(R.string.error_could_not_load)
        }
        return view
    }

    private fun readBanner() {
        val webView = navigator.session.webView
        webView.evaluateJavascript(BannerColors.READ_SCRIPT) { value ->
            if (isAdded) apply(BannerColors.parse(value, fallback = colors) ?: Theme.fallbackBanner(requireContext()))
        }
    }

    fun apply(colors: BannerColors) {
        this.colors = colors
        BannerColors.current = colors
        val view = view ?: return
        view.findViewById<View>(dev.hotwire.navigation.R.id.app_bar)?.setBackgroundColor(colors.background)
        (toolbarForNavigation() as? MaterialToolbar)?.apply {
            setBackgroundColor(colors.background)
            setTitleTextColor(colors.title)
            setNavigationIconTint(colors.accent)
            menu.findItem(R.id.menu_app_settings)?.iconTintList = ColorStateList.valueOf(colors.accent)
        }
        if (isResumed) {
            activity?.window?.let { window ->
                WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightStatusBars = !colors.isDark
            }
        }
    }

    private fun addSettingsButton() {
        val toolbar = toolbarForNavigation() ?: return
        if (toolbar.menu.findItem(R.id.menu_app_settings) != null) return
        toolbar.menu.add(0, R.id.menu_app_settings, 0, R.string.app_settings).apply {
            setIcon(R.drawable.ic_account_circle)
            setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
            contentDescription = getString(R.string.app_settings)
        }
        toolbar.setOnMenuItemClickListener { item ->
            if (item.itemId == R.id.menu_app_settings) {
                (activity as? MainActivity)?.openSettings()
                true
            } else {
                false
            }
        }
    }

    companion object {
        fun shortTitle(title: String?): String = title.orEmpty().removeSuffix(" · Rupert")
    }
}

/** Opening the camera or a file picker for an attachment must not lock the app on return. */
class RupertWebChromeClient(session: Session) : HotwireWebChromeClient(session) {
    override fun onShowFileChooser(
        webView: WebView,
        filePathCallback: ValueCallback<Array<Uri>>,
        fileChooserParams: WebChromeClient.FileChooserParams
    ): Boolean {
        AppLock.allowExternalScreen()
        return super.onShowFileChooser(webView, filePathCallback, fileChooserParams)
    }
}
