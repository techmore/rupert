package com.rupertpos.rupert

import android.webkit.CookieManager
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

/** A problem to show the person, in Rupert's words. */
class SignInProblem(message: String) : IOException(message)

/** A Set-Cookie header and the URL that sent it, for copying into the web views' cookie store. */
data class ReceivedCookie(val url: String, val header: String)

/** A session Rupert started for the app: the cookies to keep and the page to open. */
data class StartedSession(val landing: String, val cookies: List<ReceivedCookie>)

/**
 * The app's own requests to Rupert (Google sign-in code, workspace handoff, server check). They
 * never share the web views' cookies: each call collects what it receives, and only the session
 * cookie of the site that answered is handed to the web views (CookieManager).
 */
object NativeHttp {
    private val json = "application/json".toMediaType()

    /** No cache, no shared cookies, no https → http redirects. */
    private val base: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .followSslRedirects(false)
        .build()

    /**
     * POST /native/session {code, verifier}: trades the one-time Google code for Rupert's normal
     * session cookie (web/app/controllers/native/sessions_controller.rb).
     */
    fun redeemGoogleCode(site: String, code: String, verifier: String, userAgent: String): StartedSession {
        val endpoint = InstanceAddress.url("/native/session", site)
        val body = JSONObject().put("code", code).put("verifier", verifier).toString().toRequestBody(json)
        val request = Request.Builder().url(endpoint).post(body)
            .header("Accept", "application/json")
            .header("User-Agent", userAgent)
            .build()

        val collector = CookieCollector()
        base.newBuilder().cookieJar(collector).followRedirects(false).build().newCall(request).execute().use { response ->
            val text = response.body.string()
            val payload = runCatching { JSONObject(text) }.getOrNull()
            if (response.code != 200) {
                throw SignInProblem(payload?.optString("error")?.ifBlank { null }
                    ?: "Rupert did not accept the sign-in. Try again.")
            }
            val cookies = collector.forHost(InstanceAddress.hostOf(site))
            if (cookies.isEmpty()) throw SignInProblem("Rupert did not start a session. Try again.")
            val location = payload?.optString("location")?.ifBlank { null } ?: "/"
            val landing = InstanceAddress.url(location, site)
            return StartedSession(if (InstanceAddress.originOf(landing) == site) landing else "$site/", cookies)
        }
    }

    /**
     * POST <origin>/instance/session handoff=…: what the browser's handoff form does. The instance
     * accepts the handoff only with its control plane as the Origin header.
     */
    fun exchangeHandoff(link: WorkspaceLink, userAgent: String): StartedSession {
        val request = Request.Builder()
            .url(InstanceAddress.url("/instance/session", link.origin))
            .post(FormBody.Builder().add("handoff", link.handoff).build())
            .header("Origin", link.control)
            .header("User-Agent", userAgent)
            .build()

        // A private cookie jar carries the instance's session across its redirect to the landing page.
        val collector = CookieCollector()
        base.newBuilder().cookieJar(collector).followRedirects(true).build().newCall(request).execute().use { response ->
            val text = response.body.string().trim()
            if (response.code !in 200..299) {
                throw SignInProblem(
                    if (text.isNotEmpty() && text.length < 300 && !text.startsWith("<")) text
                    else "The workspace did not accept the sign-in. Go back and try again."
                )
            }
            val cookies = collector.forHost(InstanceAddress.hostOf(link.origin))
            if (cookies.isEmpty()) throw SignInProblem("The workspace did not start a session. Try again.")
            val finalUrl = response.request.url.toString()
            val landing = if (InstanceAddress.originOf(finalUrl) == link.origin) finalUrl else "${link.origin}/"
            return StartedSession(landing, cookies)
        }
    }

    /** What checking a server address found. */
    sealed interface Probe {
        data object Rupert : Probe
        data class Problem(val reason: String) : Probe
    }

    /** Checks that `origin` answers like Rupert: it serves the app's navigation rules. */
    fun probe(origin: String, userAgent: String): Probe {
        val client = base.newBuilder()
            .followRedirects(false)
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()
        // Older Rupert servers only publish the iPhone copy of the same rules.
        val paths = listOf("/native/android/path-configuration.json", "/native/ios/path-configuration.json")
        var answered = false
        for (path in paths) {
            val request = Request.Builder().url(InstanceAddress.url(path, origin))
                .header("Accept", "application/json")
                .header("User-Agent", userAgent)
                .build()
            try {
                client.newCall(request).execute().use { response ->
                    answered = true
                    if (response.code == 200) {
                        val rules = runCatching { JSONObject(response.body.string()).optJSONArray("rules") }.getOrNull()
                        if (rules != null) return Probe.Rupert
                    }
                }
            } catch (error: IOException) {
                if (!answered) {
                    return Probe.Problem(
                        "Rupert could not reach that server. Check the address and that this phone is on " +
                            "the right network. (${error.message ?: error.javaClass.simpleName})"
                    )
                }
            }
        }
        return Probe.Problem("That server answered, but it is not a Rupert server.")
    }

    /** Copies a started session's cookies into the web views' store. */
    suspend fun install(session: StartedSession) {
        val manager = CookieManager.getInstance()
        for (cookie in session.cookies) {
            suspendCoroutine { continuation ->
                manager.setCookie(cookie.url, cookie.header) { continuation.resume(Unit) }
            }
        }
        manager.flush()
    }

    /** Keeps cookies for the requests of one call, and the raw headers to hand to the web views. */
    private class CookieCollector : CookieJar {
        private val jar = mutableListOf<Cookie>()
        private val received = mutableListOf<Pair<HttpUrl, Cookie>>()

        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
            for (cookie in cookies) {
                jar.removeAll { it.name == cookie.name && it.domain == cookie.domain && it.path == cookie.path }
                jar.add(cookie)
                received.add(url to cookie)
            }
        }

        override fun loadForRequest(url: HttpUrl): List<Cookie> =
            jar.filter { it.matches(url) && it.expiresAt > System.currentTimeMillis() }

        fun forHost(host: String): List<ReceivedCookie> =
            received.filter { (url, _) -> url.host.equals(host, ignoreCase = true) }
                .map { (url, cookie) -> ReceivedCookie(url.newBuilder().encodedPath("/").query(null).build().toString(), cookie.toSetCookieHeader()) }
    }

    /** okhttp's Cookie.toString() is a Set-Cookie value; keep SameSite, which CookieManager understands. */
    private fun Cookie.toSetCookieHeader(): String {
        val header = toString()
        return sameSite?.let { if (header.contains("samesite", ignoreCase = true)) header else "$header; SameSite=$it" } ?: header
    }

    internal fun String.toHttpUrlOrThrow(): HttpUrl = toHttpUrlOrNull() ?: throw SignInProblem("Rupert sent an address the app cannot open.")
}
