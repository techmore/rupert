package com.rupertpos.rupert

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = TestApplication::class)
class BannerColorsTest {
    @Test fun `reads the page's colours as evaluateJavascript returns them`() {
        val result = "\"{\\\"banner\\\":\\\"#cce0dc\\\",\\\"ink\\\":\\\"#17353a\\\",\\\"accent\\\":\\\"#0e6f72\\\"}\""
        val colors = BannerColors.parse(result)!!
        assertEquals(0xFFCCE0DC.toInt(), colors.background)
        assertEquals(0xFF17353A.toInt(), colors.title)
        assertEquals(0xFF0E6F72.toInt(), colors.accent)
        assertFalse(colors.isDark)
    }

    @Test fun `reads the watcher's message and short hex`() {
        val colors = BannerColors.parse("{\"banner\":\"#123\",\"ink\":\"\",\"accent\":\"#fff\"}")!!
        assertEquals(0xFF112233.toInt(), colors.background)
        assertTrue(colors.isDark)
        assertEquals(-0x1, colors.title)
    }

    @Test fun `pages without the token give nothing`() {
        assertNull(BannerColors.parse(null))
        assertNull(BannerColors.parse("null"))
        assertNull(BannerColors.parse("\"{\\\"banner\\\":\\\"\\\"}\""))
        assertNull(BannerColors.parse("not json"))
        assertNull(BannerColors.hex("rgb(1,2,3)"))
    }

    @Test fun `scanned codes are quoted for the page`() {
        val script = BarcodeScanner.scannedScript("12\"3</script>'")
        assertTrue(script.startsWith("window.dispatchEvent(new CustomEvent('rupert:scanned', { detail: [\"12\\\"3<\\/script>'\"][0] }))"))
    }

    @Test fun `page diagnostics read as lines`() {
        val report = WebViewSupport.format(
            "\"{\\\"turbo\\\":\\\"undefined\\\",\\\"hotwire\\\":\\\"object\\\",\\\"ready\\\":\\\"complete\\\",\\\"importmap\\\":true,\\\"modules\\\":2,\\\"problems\\\":[\\\"could not load x.js\\\"],\\\"page\\\":\\\"/chat\\\",\\\"agent\\\":\\\"UA\\\"}\""
        )
        assertEquals("Page: /chat\nTurbo: undefined · Hotwire: object · complete\nImport map: true · modules: 2\ncould not load x.js\nUA", report)
        assertEquals("No page details (the page did not run any script).", WebViewSupport.format("null"))
    }

    @Test fun `titles drop the browser suffix`() {
        assertEquals("Team Chat", RupertWebFragment.shortTitle("Team Chat · Rupert"))
        assertEquals("Orders", RupertWebFragment.shortTitle("Orders"))
    }
}
