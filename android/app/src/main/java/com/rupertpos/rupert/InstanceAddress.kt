package com.rupertpos.rupert

import java.net.URI
import java.net.URISyntaxException

/**
 * Rules for the Rupert server addresses the app may use. Plain Kotlin (no Android types), so the
 * unit tests cover every rule.
 *
 * Public servers must use https. Plain http is allowed only for this device and for local network
 * names, and those names must also be listed in res/xml/network_security_config.xml, which is what
 * actually permits the traffic (NetworkSecurityConfigTest checks the two lists agree).
 */
object InstanceAddress {
    sealed interface Result {
        data class Valid(val origin: String) : Result
        data class Invalid(val reason: String) : Result
    }

    /** Addresses that may use plain http: the phone itself and the emulator's view of the computer. */
    val localHosts = setOf("127.0.0.1", "10.0.2.2")

    /** Names (and their subdomains) that may use plain http: localhost and local network names (RFC 6761, 6762, 8375). */
    val localSuffixes = listOf("local", "lan", "internal", "home.arpa", "localhost")

    /** Turns what a person typed into a clean origin (scheme://host[:port]) or says what is wrong. */
    fun parse(input: String): Result {
        var text = input.trim()
        if (text.isEmpty()) {
            return Result.Invalid("Enter your Rupert address, for example pos.rupertpos.com.")
        }
        if (!text.contains("://")) text = "https://$text"

        val uri = try {
            URI(text)
        } catch (_: URISyntaxException) {
            return Result.Invalid("That is not a web address. Check for spaces or typos.")
        }

        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && scheme != "http") {
            return Result.Invalid("Use an address that starts with https://.")
        }
        if (uri.rawUserInfo != null) {
            return Result.Invalid("Leave out any user name or password. You sign in on the next page.")
        }
        val host = uri.host?.lowercase()?.trimEnd('.')
        if (host.isNullOrEmpty()) {
            return Result.Invalid("That address has no server name.")
        }
        val path = uri.rawPath.orEmpty()
        if ((path.isNotEmpty() && path != "/") || uri.rawQuery != null || uri.rawFragment != null) {
            return Result.Invalid("Enter only the server address, without a page after it.")
        }
        if (scheme == "http" && !isLocal(host)) {
            return Result.Invalid(
                "Rupert needs https:// for this address. Plain http:// works only for this device " +
                    "and local names ending in .local, .lan, .internal or .home.arpa."
            )
        }

        val defaultPort = if (scheme == "https") 443 else 80
        val port = if (uri.port == -1 || uri.port == defaultPort) "" else ":${uri.port}"
        return Result.Valid("$scheme://$host$port")
    }

    fun isLocal(host: String): Boolean {
        val name = host.lowercase().trimEnd('.')
        return name in localHosts || localSuffixes.any { name == it || name.endsWith(".$it") }
    }

    /**
     * scheme://host[:port] of an http(s) URL, or null. Plain http counts only for local hosts, so a
     * page can never move the app onto an unencrypted public address.
     */
    fun originOf(url: String?): String? {
        if (url.isNullOrBlank()) return null
        val uri = try {
            URI(url)
        } catch (_: URISyntaxException) {
            return null
        }
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase()?.trimEnd('.') ?: return null
        if (host.isEmpty()) return null
        if (scheme != "https" && !(scheme == "http" && isLocal(host))) return null
        val defaultPort = if (scheme == "https") 443 else 80
        val port = if (uri.port == -1 || uri.port == defaultPort) "" else ":${uri.port}"
        return "$scheme://$host$port"
    }

    /** https://host[:port] of a URL, or null when it is not https (handoffs and sign-in sites). */
    fun httpsOrigin(url: String?): String? = originOf(url)?.takeIf { it.startsWith("https://") }

    /**
     * Rupert's own sites stay inside the app: rupertpos.com and its subdomains over https, the
     * control plane and the current instance (an isolated workspace may live on its own domain).
     */
    fun isRupert(url: String?, controlPlane: String, current: String): Boolean {
        val origin = originOf(url) ?: return false
        if (origin == controlPlane || origin == current) return true
        if (!origin.startsWith("https://")) return false
        val host = hostOf(origin)
        return host == "rupertpos.com" || host.endsWith(".rupertpos.com") ||
            host == hostOf(controlPlane) || host == hostOf(current)
    }

    /** A path (which may carry a query) on an origin. */
    fun url(path: String, origin: String): String =
        if (path.startsWith("http://") || path.startsWith("https://")) path
        else origin.trimEnd('/') + "/" + path.trimStart('/')

    /** The path of a URL ("/" when it has none). */
    fun pathOf(url: String?): String = try {
        URI(url.orEmpty()).rawPath?.ifEmpty { "/" } ?: "/"
    } catch (_: URISyntaxException) {
        "/"
    }

    fun hostOf(origin: String): String = try {
        URI(origin).host?.lowercase().orEmpty()
    } catch (_: URISyntaxException) {
        ""
    }
}
