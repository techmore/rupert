package com.rupertpos.rupert

import java.net.URI
import java.net.URISyntaxException
import java.net.URLDecoder

/**
 * rupert:// links: Rupert talking to the app, never opened anywhere else.
 *
 * - rupert://workspace?origin=…&handoff=…&control=… answers "Open my workspace" inside the app
 *   (web/app/controllers/workspaces_controller.rb, NativeSignIn.workspace_url).
 * - rupert://auth/google?code=… (or ?error= / ?message=) ends Google sign-in in the browser tab
 *   (NativeSignIn.callback_url).
 */
object RupertLinks {
    const val SCHEME = "rupert"

    fun isRupertScheme(url: String?): Boolean = url?.lowercase()?.startsWith("$SCHEME:") == true

    fun query(url: String): Map<String, String> {
        val raw = try {
            URI(url).rawQuery
        } catch (_: URISyntaxException) {
            null
        } ?: return emptyMap()
        return raw.split('&').filter { it.isNotEmpty() }.associate { pair ->
            val name = pair.substringBefore('=')
            val value = if ('=' in pair) pair.substringAfter('=') else ""
            decode(name) to decode(value)
        }
    }

    fun host(url: String): String? = try {
        URI(url).host?.lowercase()
    } catch (_: URISyntaxException) {
        null
    }

    fun path(url: String): String = try {
        URI(url).rawPath.orEmpty()
    } catch (_: URISyntaxException) {
        ""
    }

    private fun decode(value: String): String = URLDecoder.decode(value, "UTF-8")
}

/** rupert://workspace?origin=INSTANCE&handoff=ONE_TIME_CODE&control=CONTROL_PLANE. */
data class WorkspaceLink(val origin: String, val handoff: String, val control: String) {
    companion object {
        /** Null when the link is incomplete or names a non-https site. */
        fun parse(url: String): WorkspaceLink? {
            if (!RupertLinks.isRupertScheme(url) || RupertLinks.host(url) != "workspace") return null
            val query = RupertLinks.query(url)
            val origin = InstanceAddress.httpsOrigin(query["origin"]) ?: return null
            val control = InstanceAddress.httpsOrigin(query["control"]) ?: return null
            val handoff = query["handoff"]?.takeIf { it.isNotBlank() } ?: return null
            return WorkspaceLink(origin, handoff, control)
        }
    }
}

/** What the browser tab answered at the end of Google sign-in. */
sealed interface GoogleCallback {
    data class Code(val code: String) : GoogleCallback
    data class Refused(val message: String) : GoogleCallback
    /** A sign-up receipt ("we'll email you when your workspace is ready"). */
    data class Notice(val message: String) : GoogleCallback
    data object Incomplete : GoogleCallback

    companion object {
        fun isCallback(url: String?): Boolean =
            url != null && RupertLinks.isRupertScheme(url) && RupertLinks.host(url) == "auth" &&
                RupertLinks.path(url) == "/google"

        fun parse(url: String): GoogleCallback {
            if (!isCallback(url)) return Incomplete
            val query = RupertLinks.query(url)
            query["error"]?.takeIf { it.isNotBlank() }?.let { return Refused(it) }
            query["message"]?.takeIf { it.isNotBlank() }?.let { return Notice(it) }
            return query["code"]?.takeIf { it.isNotBlank() }?.let(::Code) ?: Incomplete
        }
    }
}
