package com.rupertpos.rupert

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RupertLinksTest {
    @Test fun `workspace links carry an https instance, its control plane and the handoff`() {
        val link = WorkspaceLink.parse(
            "rupert://workspace?origin=https%3A%2F%2Fshop.example.org&handoff=abc%2B123%3D&control=https%3A%2F%2Fpos.rupertpos.com"
        )
        assertEquals(WorkspaceLink("https://shop.example.org", "abc+123=", "https://pos.rupertpos.com"), link)
    }

    @Test fun `incomplete or unsafe workspace links are refused`() {
        assertNull(WorkspaceLink.parse("rupert://workspace?origin=https%3A%2F%2Fshop.example.org&control=https%3A%2F%2Fpos.rupertpos.com"))
        assertNull(WorkspaceLink.parse("rupert://workspace?origin=http%3A%2F%2Fshop.example.org&handoff=x&control=https%3A%2F%2Fpos.rupertpos.com"))
        assertNull(WorkspaceLink.parse("rupert://workspace?origin=javascript%3Aalert(1)&handoff=x&control=https%3A%2F%2Fpos.rupertpos.com"))
        assertNull(WorkspaceLink.parse("rupert://other?origin=https%3A%2F%2Fshop.example.org&handoff=x&control=https%3A%2F%2Fpos.rupertpos.com"))
        assertNull(WorkspaceLink.parse("https://pos.rupertpos.com/workspace"))
    }

    @Test fun `Google callbacks`() {
        assertTrue(GoogleCallback.isCallback("rupert://auth/google?code=x"))
        assertFalse(GoogleCallback.isCallback("rupert://auth/other?code=x"))
        assertFalse(GoogleCallback.isCallback("https://pos.rupertpos.com/auth/google"))
        assertEquals(GoogleCallback.Code("a b+c"), GoogleCallback.parse("rupert://auth/google?code=a%20b%2Bc"))
        assertEquals(GoogleCallback.Refused("No account for that email"), GoogleCallback.parse("rupert://auth/google?error=No+account+for+that+email"))
        assertEquals(GoogleCallback.Notice("We will email you"), GoogleCallback.parse("rupert://auth/google?message=We%20will%20email%20you"))
        assertEquals(GoogleCallback.Incomplete, GoogleCallback.parse("rupert://auth/google"))
    }
}
