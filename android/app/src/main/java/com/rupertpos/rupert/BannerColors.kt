package com.rupertpos.rupert

import org.json.JSONObject
import org.json.JSONTokener

/**
 * The native top bar and Rupert's own header (`.app-topbar`) read as one solid banner. Rupert
 * publishes the banner colour as `--color-banner` in every appearance (application.css); the app
 * reads it after each page and again whenever the person switches appearance in the account menu.
 * Colours are ARGB ints.
 */
data class BannerColors(val background: Int, val title: Int, val accent: Int) {
    /** Dark banners get light status bar icons, light banners dark ones, whatever the phone's setting. */
    val isDark: Boolean
        get() {
            val red = (background shr 16 and 0xff) / 255.0
            val green = (background shr 8 and 0xff) / 255.0
            val blue = (background and 0xff) / 255.0
            return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.5
        }

    companion object {
        /** A function that returns the page's banner, text and accent colours, as a JSON string. */
        private const val READ_FUNCTION = """() => {
  const css = getComputedStyle(document.documentElement);
  const value = (name) => css.getPropertyValue(name).trim();
  return JSON.stringify({ banner: value("--color-banner"), ink: value("--color-ink"), accent: value("--color-olive") });
}"""

        /** Reads the colours once (evaluateJavascript after each page). */
        const val READ_SCRIPT = "($READ_FUNCTION)()"

        /** Tells the app when the person picks another appearance (theme_controller sets data-theme). */
        const val WATCH_SCRIPT = """(() => {
  const read = $READ_FUNCTION;
  const post = () => { try { window.rupertBanner && window.rupertBanner.postMessage(read()); } catch (_) {} };
  const watch = () => new MutationObserver(post).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  if (document.documentElement) watch(); else addEventListener("DOMContentLoaded", watch);
})();"""

        /** Before the first page, and for pages without the token: the app's own colours. */
        @Volatile var current: BannerColors? = null

        /**
         * From READ_SCRIPT's JSON, or from evaluateJavascript's result (that JSON as a JSON string).
         * Null when the page has no banner token (another site, an older Rupert).
         */
        fun parse(value: String?, fallback: BannerColors? = null): BannerColors? {
            if (value.isNullOrBlank() || value == "null") return null
            val text = runCatching {
                when (val decoded = JSONTokener(value).nextValue()) {
                    is String -> decoded
                    is JSONObject -> decoded.toString()
                    else -> null
                }
            }.getOrNull() ?: return null
            val values = runCatching { JSONObject(text) }.getOrNull() ?: return null
            val background = hex(values.optString("banner")) ?: return null
            return BannerColors(
                background = background,
                title = hex(values.optString("ink")) ?: fallback?.title ?: if (isDarkColor(background)) WHITE else BLACK,
                accent = hex(values.optString("accent")) ?: fallback?.accent ?: if (isDarkColor(background)) WHITE else BLACK,
            )
        }

        /** "#rrggbb" or "#rgb", as CSS custom properties hold them. */
        fun hex(value: String?): Int? {
            var digits = value?.trim()?.takeIf { it.startsWith("#") }?.substring(1) ?: return null
            if (digits.length == 3) digits = digits.map { "$it$it" }.joinToString("")
            if (digits.length != 6) return null
            val rgb = digits.toIntOrNull(16) ?: return null
            return (0xff shl 24) or rgb
        }

        private fun isDarkColor(color: Int) = BannerColors(color, 0, 0).isDark

        private const val WHITE = -0x1
        private const val BLACK = -0x1000000
    }
}
