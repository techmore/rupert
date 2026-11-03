package com.rupertpos.rupert

import com.rupertpos.rupert.InstanceAddress.Result.Invalid
import com.rupertpos.rupert.InstanceAddress.Result.Valid
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InstanceAddressTest {
    private fun valid(input: String) = (InstanceAddress.parse(input) as? Valid)?.origin

    @Test fun `bare host names become https origins`() {
        assertEquals("https://pos.rupertpos.com", valid("pos.rupertpos.com"))
        assertEquals("https://pos.rupertpos.com", valid("  HTTPS://POS.RupertPOS.com/  "))
        assertEquals("https://sonder.stoverparc.org", valid("https://sonder.stoverparc.org"))
    }

    @Test fun `ports are kept unless they are the default`() {
        assertEquals("https://rupert.example.com:8443", valid("https://rupert.example.com:8443"))
        assertEquals("https://rupert.example.com", valid("https://rupert.example.com:443"))
        assertEquals("http://10.0.2.2:3000", valid("http://10.0.2.2:3000"))
    }

    @Test fun `plain http only for this device and local names`() {
        assertEquals("http://localhost:3000", valid("http://localhost:3000"))
        assertEquals("http://127.0.0.1", valid("http://127.0.0.1:80"))
        assertEquals("http://rupert.local:3000", valid("http://rupert.local:3000"))
        assertEquals("http://shop.lan", valid("http://shop.lan"))
        assertEquals("http://pos.home.arpa", valid("http://pos.home.arpa"))
        assertEquals("http://pos.corp.internal", valid("http://pos.corp.internal"))
        assertTrue(InstanceAddress.parse("http://pos.rupertpos.com") is Invalid)
        assertTrue(InstanceAddress.parse("http://192.168.1.20:3000") is Invalid)
        assertTrue(InstanceAddress.parse("http://notlocal.example") is Invalid)
    }

    @Test fun `rejects what is not a plain server address`() {
        listOf(
            "", "   ", "ftp://pos.rupertpos.com", "javascript:alert(1)", "file:///etc/hosts",
            "https://user:secret@pos.rupertpos.com", "https://pos.rupertpos.com/login",
            "https://pos.rupertpos.com/?x=1", "https://pos.rupertpos.com/#top", "https://exa mple.com", "https://",
        ).forEach { input ->
            assertTrue("$input should be refused", InstanceAddress.parse(input) is Invalid)
        }
    }

    @Test fun `origins of links only for https or local http`() {
        assertEquals("https://pos.rupertpos.com", InstanceAddress.originOf("https://pos.rupertpos.com/chat?x=1"))
        assertEquals("http://10.0.2.2:3000", InstanceAddress.originOf("http://10.0.2.2:3000/login"))
        assertNull(InstanceAddress.originOf("http://pos.rupertpos.com/chat"))
        assertNull(InstanceAddress.originOf("rupert://workspace?origin=x"))
        assertNull(InstanceAddress.httpsOrigin("http://localhost:3000"))
    }

    @Test fun `Rupert's own sites`() {
        val control = "https://pos.rupertpos.com"
        val workspace = "https://shop.example.org"
        assertTrue(InstanceAddress.isRupert("https://pos.rupertpos.com/chat", control, control))
        assertTrue(InstanceAddress.isRupert("https://help.rupertpos.com/x", control, control))
        assertTrue(InstanceAddress.isRupert("https://rupertpos.com/", control, control))
        assertTrue(InstanceAddress.isRupert("https://shop.example.org/orders", control, workspace))
        assertFalse(InstanceAddress.isRupert("https://shop.example.org/orders", control, control))
        assertFalse(InstanceAddress.isRupert("https://evilrupertpos.com/", control, control))
        assertFalse(InstanceAddress.isRupert("https://rupertpos.com.evil.example/", control, control))
        assertFalse(InstanceAddress.isRupert("http://pos.rupertpos.com/", control, control))
        assertFalse(InstanceAddress.isRupert("https://accounts.google.com/", control, control))
        assertTrue(InstanceAddress.isRupert("http://10.0.2.2:3000/chat", "http://10.0.2.2:3000", "http://10.0.2.2:3000"))
        assertFalse(InstanceAddress.isRupert("http://10.0.2.2:4000/chat", "http://10.0.2.2:3000", "http://10.0.2.2:3000"))
    }

    @Test fun `paths and urls`() {
        assertEquals("https://pos.rupertpos.com/chat", InstanceAddress.url("/chat", "https://pos.rupertpos.com"))
        assertEquals("https://pos.rupertpos.com/a?b=1", InstanceAddress.url("a?b=1", "https://pos.rupertpos.com/"))
        assertEquals("/login", InstanceAddress.pathOf("https://pos.rupertpos.com/login?next=1"))
        assertEquals("/", InstanceAddress.pathOf("https://pos.rupertpos.com"))
    }
}
