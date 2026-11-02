package com.rupertpos.rupert

import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.core.net.toUri
import dev.hotwire.core.turbo.visit.VisitProposal
import dev.hotwire.navigation.activities.HotwireActivity
import dev.hotwire.navigation.navigator.NavigatorConfiguration
import dev.hotwire.navigation.routing.BrowserTabRouteDecisionHandler
import dev.hotwire.navigation.routing.Router

/**
 * Where each link goes, in this order (Hotwire Android proposes every main-frame navigation,
 * including plain `data-turbo="false"` links and redirects, so these see all of them):
 * 1. Google sign-in and sign-up go to a browser tab (GoogleSignIn).
 * 2. rupert:// links are Rupert talking to the app (workspace handoff).
 * 3. Every Rupert site (control plane and workspaces) stays in the app.
 * 4. Other websites open in a browser tab; mailto:, tel:, sms: and geo: in their apps.
 * Anything else is dropped.
 */
object Routing {
    val handlers: Array<Router.RouteDecisionHandler> = arrayOf(
        GoogleSignInRoute(),
        RupertSchemeRoute(),
        RupertSitesRoute(),
        OtherSitesRoute(),
        SystemSchemesRoute(),
    )
}

class GoogleSignInRoute : Router.RouteDecisionHandler {
    override val name = "rupert-google-sign-in"

    override fun matches(proposal: VisitProposal, configuration: NavigatorConfiguration): Boolean =
        Instance.isRupert(proposal.location) && InstanceAddress.pathOf(proposal.location) == "/auth/google"

    override fun handle(proposal: VisitProposal, configuration: NavigatorConfiguration, activity: HotwireActivity): Router.Decision {
        (activity as? MainActivity)?.startGoogleSignIn(proposal.location)
        return Router.Decision.CANCEL
    }
}

class RupertSchemeRoute : Router.RouteDecisionHandler {
    override val name = "rupert-scheme"

    override fun matches(proposal: VisitProposal, configuration: NavigatorConfiguration): Boolean =
        RupertLinks.isRupertScheme(proposal.location)

    override fun handle(proposal: VisitProposal, configuration: NavigatorConfiguration, activity: HotwireActivity): Router.Decision {
        if (RupertLinks.host(proposal.location) == "workspace") {
            (activity as? MainActivity)?.openWorkspace(proposal.location)
        }
        return Router.Decision.CANCEL
    }
}

/** Hotwire's default keeps only the tab's starting host, so the control plane → workspace hop would leave the app. */
class RupertSitesRoute : Router.RouteDecisionHandler {
    override val name = "rupert-sites"

    override fun matches(proposal: VisitProposal, configuration: NavigatorConfiguration): Boolean =
        Instance.isRupert(proposal.location)

    override fun handle(proposal: VisitProposal, configuration: NavigatorConfiguration, activity: HotwireActivity) =
        Router.Decision.NAVIGATE
}

class OtherSitesRoute : Router.RouteDecisionHandler {
    override val name = "other-sites"
    private val browserTab = BrowserTabRouteDecisionHandler()

    override fun matches(proposal: VisitProposal, configuration: NavigatorConfiguration): Boolean {
        val scheme = proposal.location.toUri().scheme?.lowercase()
        return scheme == "https" || scheme == "http"
    }

    override fun handle(proposal: VisitProposal, configuration: NavigatorConfiguration, activity: HotwireActivity): Router.Decision {
        AppLock.allowExternalScreen()
        return browserTab.handle(proposal, configuration, activity)
    }
}

class SystemSchemesRoute : Router.RouteDecisionHandler {
    override val name = "system-schemes"
    private val schemes = setOf("mailto", "tel", "sms", "geo")

    override fun matches(proposal: VisitProposal, configuration: NavigatorConfiguration): Boolean =
        proposal.location.toUri().scheme?.lowercase() in schemes

    override fun handle(proposal: VisitProposal, configuration: NavigatorConfiguration, activity: HotwireActivity): Router.Decision {
        try {
            AppLock.allowExternalScreen()
            activity.startActivity(Intent(Intent.ACTION_VIEW, proposal.location.toUri()))
        } catch (_: ActivityNotFoundException) {
            // No app for it on this phone; the link does nothing, as in a browser without one.
        }
        return Router.Decision.CANCEL
    }
}
