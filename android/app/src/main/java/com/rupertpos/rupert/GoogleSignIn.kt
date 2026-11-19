package com.rupertpos.rupert

import android.app.Activity
import android.content.ActivityNotFoundException
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.net.toUri

/**
 * Google sign-in for the app. Rupert's side is web/app/services/native_sign_in.rb:
 *
 * 1. A random verifier stays in memory here; its SHA-256 (the challenge) goes to /auth/google.
 * 2. Google signs the person in inside a browser tab (Custom Tab), because Google refuses
 *    sign-in inside embedded web views. Rupert answers with rupert://auth/google?code=CODE (or
 *    ?error= / ?message=) instead of a browser session. A sign-up form's `intent` rides along.
 * 3. POST /native/session {code, verifier} returns Rupert's session cookie, which is copied into
 *    the web views' cookie store. A code is useless without the verifier and works once, so another
 *    app that claims the rupert:// scheme cannot use an intercepted code.
 */
object GoogleSignIn {
    private data class Pending(val site: String, val verifier: String)

    private var pending: Pending? = null

    /** The URL the browser tab opens: Rupert's /auth/google with the challenge and any sign-up intent. */
    fun authorizationUrl(link: String, verifier: String): String? {
        val site = InstanceAddress.originOf(link) ?: return null
        val builder = InstanceAddress.url("/auth/google", site).toUri().buildUpon()
        link.toUri().getQueryParameter("intent")?.takeIf { it.isNotBlank() }?.let { builder.appendQueryParameter("intent", it) }
        builder.appendQueryParameter("native_challenge", Pkce.challenge(verifier))
        return builder.build().toString()
    }

    /** `link` is Rupert's /auth/google link (a tap, or a sign-up form's redirect). */
    fun start(activity: Activity, link: String, onProblem: (String) -> Unit) {
        val verifier = Pkce.randomVerifier()
        val url = authorizationUrl(link, verifier) ?: return onProblem("Google sign-in needs a Rupert address. Try again.")
        pending = Pending(InstanceAddress.originOf(link)!!, verifier)
        AppLock.allowExternalScreen()
        try {
            CustomTabsIntent.Builder()
                .setShowTitle(true)
                .setShareState(CustomTabsIntent.SHARE_STATE_OFF)
                .build()
                .launchUrl(activity, url.toUri())
        } catch (_: ActivityNotFoundException) {
            pending = null
            onProblem("Google sign-in needs a web browser on this phone, such as Chrome.")
        }
    }

    /**
     * The browser tab came back with rupert://auth/google?…. Returns what to do next; the code is
     * redeemed by the caller (network) with the verifier this returns.
     */
    fun finish(callback: String): Outcome {
        val started = pending ?: return Outcome.NotStarted
        pending = null
        return when (val result = GoogleCallback.parse(callback)) {
            is GoogleCallback.Code -> Outcome.Redeem(started.site, result.code, started.verifier)
            is GoogleCallback.Refused -> Outcome.Problem(result.message)
            is GoogleCallback.Notice -> Outcome.Notice(result.message)
            GoogleCallback.Incomplete -> Outcome.Problem("Google sign-in did not finish. Try again.")
        }
    }

    sealed interface Outcome {
        data class Redeem(val site: String, val code: String, val verifier: String) : Outcome
        data class Problem(val message: String) : Outcome
        data class Notice(val message: String) : Outcome
        /** No sign-in was waiting (an old link, or another app sending one): ignore it. */
        data object NotStarted : Outcome
    }
}
