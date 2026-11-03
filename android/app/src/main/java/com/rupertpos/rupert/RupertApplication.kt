package com.rupertpos.rupert

import android.app.Application
import android.content.Context
import androidx.core.content.ContextCompat
import dev.hotwire.core.config.Hotwire
import dev.hotwire.core.logging.HotwireLogLevel
import dev.hotwire.core.turbo.config.PathConfiguration
import dev.hotwire.navigation.config.defaultFragmentDestination
import dev.hotwire.navigation.config.registerFragmentDestinations
import dev.hotwire.navigation.config.registerRouteDecisionHandlers

open class RupertApplication : Application() {
    /** Tests turn this off so they never reach the real server. */
    open val loadsRemotePathConfiguration: Boolean = true

    override fun onCreate() {
        super.onCreate()
        Instance.init(this)
        AppLock.init(this)
        configureHotwire()
    }

    private fun configureHotwire() {
        loadPathConfiguration(this)

        // Rupert recognises the app by "Hotwire Native" in the user agent (turbo-rails'
        // hotwire_native_app?) and drops the web chrome the native tab bar replaces.
        Hotwire.config.applicationUserAgentPrefix = "Rupert Android/${Instance.appVersion};"
        Hotwire.config.makeCustomWebView = { context -> RupertWebView(context) }
        Hotwire.defaultFragmentDestination = RupertWebFragment::class
        Hotwire.registerFragmentDestinations(RupertWebFragment::class)
        Hotwire.registerRouteDecisionHandlers(*Routing.handlers)

        if (BuildConfig.DEBUG) {
            Hotwire.config.webViewDebuggingEnabled = true
            Hotwire.config.logger.logLevel = HotwireLogLevel.DEBUG
        }
    }

    companion object {
        /**
         * Rules ship with the app for the first launch and offline starts (the iPhone app's
         * path-configuration.json, copied in at build time); the server copy wins once it loads, so
         * navigation rules change with a Rupert deploy, not a Play release.
         */
        fun loadPathConfiguration(context: Context) {
            val remote = (context.applicationContext as? RupertApplication)?.loadsRemotePathConfiguration != false
            Hotwire.loadPathConfiguration(
                context = context,
                location = PathConfiguration.Location(
                    assetFilePath = "json/path-configuration.json",
                    remoteFileUrl = Instance.url("/native/android/path-configuration.json", on = Instance.controlPlane)
                        .takeIf { remote },
                ),
            )
        }
    }
}

/** The app's own colours, for before the first page and for pages without Rupert's banner token. */
object Theme {
    fun fallbackBanner(context: Context) = BannerColors(
        background = ContextCompat.getColor(context, R.color.banner),
        title = ContextCompat.getColor(context, R.color.banner_title),
        accent = ContextCompat.getColor(context, R.color.accent),
    )
}
