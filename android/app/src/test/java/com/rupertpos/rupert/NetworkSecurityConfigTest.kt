package com.rupertpos.rupert

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/** The address rules (InstanceAddress) and what Android actually permits (network_security_config.xml) agree. */
class NetworkSecurityConfigTest {
    private val document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
        .parse(File("src/main/res/xml/network_security_config.xml"))

    @Test fun `cleartext is off by default and only system certificates are trusted`() {
        val base = document.getElementsByTagName("base-config").item(0) as Element
        assertEquals("false", base.getAttribute("cleartextTrafficPermitted"))
        val certificates = base.getElementsByTagName("certificates")
        assertEquals(1, certificates.length)
        assertEquals("system", (certificates.item(0) as Element).getAttribute("src"))
    }

    @Test fun `plain http hosts match InstanceAddress`() {
        val domains = document.getElementsByTagName("domain")
        val exact = mutableSetOf<String>()
        val suffixes = mutableSetOf<String>()
        for (index in 0 until domains.length) {
            val domain = domains.item(index) as Element
            val config = domain.parentNode as Element
            assertEquals("true", config.getAttribute("cleartextTrafficPermitted"))
            if (domain.getAttribute("includeSubdomains") == "true") suffixes += domain.textContent.trim()
            else exact += domain.textContent.trim()
        }
        assertEquals(InstanceAddress.localHosts, exact)
        assertEquals(InstanceAddress.localSuffixes.toSet(), suffixes)
        assertTrue(File("src/main/AndroidManifest.xml").readText().contains("android:usesCleartextTraffic=\"false\""))
    }
}
