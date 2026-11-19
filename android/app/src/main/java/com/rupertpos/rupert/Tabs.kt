package com.rupertpos.rupert

import androidx.annotation.DrawableRes
import androidx.annotation.IdRes
import androidx.annotation.StringRes
import dev.hotwire.navigation.navigator.NavigatorConfiguration

/**
 * The native tab bar, on whichever instance the app is pointed at. These replace the web top
 * bar's search, Ask Rupert, Team chat and notification buttons, which Rupert hides inside the app
 * (`.native-app` in application.css). Signed out, every tab shows Rupert's sign-in page.
 * Same tabs, order and pages as the iPhone app (ios/Sources/Rupert/Tabs.swift).
 */
enum class RupertTab(
    val id: String,
    @StringRes val title: Int,
    @DrawableRes val icon: Int,
    val path: String,
    @IdRes val hostId: Int,
) {
    // /login sends a signed-in person to their start page, so Home never opens on a page the app
    // cannot show (the signed-out marketing page at / has no Turbo).
    HOME("home", R.string.tab_home, R.drawable.ic_tab_home, "/login", R.id.tab_home),
    CHAT("chat", R.string.tab_chat, R.drawable.ic_tab_chat, "/chat", R.id.tab_chat),
    ASK("ask", R.string.tab_ask, R.drawable.ic_tab_ask, "/ask_rupert", R.id.tab_ask),
    INBOX("inbox", R.string.tab_inbox, R.drawable.ic_tab_inbox, "/notifications", R.id.tab_inbox),
    SEARCH("search", R.string.tab_search, R.drawable.ic_tab_search, "/search", R.id.tab_search);

    fun configuration(base: String) = NavigatorConfiguration(
        name = id,
        startLocation = InstanceAddress.url(path, base),
        navigatorHostId = hostId,
    )

    companion object {
        fun index(id: String?): Int? = entries.indexOfFirst { it.id == id }.takeIf { it >= 0 }
    }
}
