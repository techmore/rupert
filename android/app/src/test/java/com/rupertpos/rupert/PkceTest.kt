package com.rupertpos.rupert

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PkceTest {
    @Test fun `challenge matches the server's NativeSignIn challenge_for`() {
        // Ruby: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        assertEquals(
            "Pj4Dcj3ojhwDaXi9PxmX9-D4e6AKiDJd1B9nEN57FsA",
            Pkce.challenge("dBjftJeZ4CVP-mJ0kz2t3RIe8Y3KRuaz0xd9hOSc4Wk"),
        )
    }

    @Test fun `verifiers and challenges have the shapes the server accepts`() {
        val verifier = Pkce.randomVerifier()
        // NativeSignIn::VERIFIER and NativeSignIn::CHALLENGE.
        assertTrue(Regex("\\A[A-Za-z0-9._~-]{43,128}\\z").matches(verifier))
        assertTrue(Regex("\\A[A-Za-z0-9_-]{43}\\z").matches(Pkce.challenge(verifier)))
        assertNotEquals(verifier, Pkce.randomVerifier())
    }
}
