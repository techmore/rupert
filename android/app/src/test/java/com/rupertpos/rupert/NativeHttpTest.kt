package com.rupertpos.rupert

import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The app's own requests, against a stand-in Rupert (MockWebServer on localhost, which may use http). */
@RunWith(RobolectricTestRunner::class)
@Config(application = TestApplication::class)
class NativeHttpTest {
    private val server = MockWebServer()
    private lateinit var site: String

    @Before fun start() {
        server.start()
        site = "http://localhost:${server.port}"
    }

    @After fun stop() = server.close()

    @Test fun `a Google code becomes a session cookie and the landing page`() {
        server.enqueue(
            MockResponse.Builder().code(200)
                .addHeader("Set-Cookie", "_rupert_session=abc; path=/; HttpOnly; SameSite=Lax")
                .body("{\"location\":\"/platform\"}").build()
        )
        val session = NativeHttp.redeemGoogleCode(site, "CODE", "VERIFIER", "Rupert Android/1; Hotwire Native Android;")

        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/native/session", request.url.encodedPath)
        assertEquals("CODE", JSONObject(request.body!!.utf8()).getString("code"))
        assertEquals("VERIFIER", JSONObject(request.body!!.utf8()).getString("verifier"))
        assertTrue(request.headers["User-Agent"]!!.contains("Hotwire Native Android"))
        assertEquals("$site/platform", session.landing)
        assertEquals(1, session.cookies.size)
        assertTrue(session.cookies.single().header.startsWith("_rupert_session=abc"))
        assertTrue(session.cookies.single().header.contains("httponly", ignoreCase = true))
    }

    @Test fun `a refused code says why`() {
        server.enqueue(MockResponse.Builder().code(422).body("{\"error\":\"That sign-in expired. Sign in with Google again.\"}").build())
        try {
            NativeHttp.redeemGoogleCode(site, "CODE", "VERIFIER", "UA")
            fail("expected a problem")
        } catch (problem: SignInProblem) {
            assertEquals("That sign-in expired. Sign in with Google again.", problem.message)
        }
    }

    @Test fun `a landing page on another site is not followed`() {
        server.enqueue(
            MockResponse.Builder().code(200).addHeader("Set-Cookie", "_rupert_session=abc; path=/")
                .body("{\"location\":\"https://evil.example/\"}").build()
        )
        assertEquals("$site/", NativeHttp.redeemGoogleCode(site, "CODE", "VERIFIER", "UA").landing)
    }

    @Test fun `the workspace handoff posts like the browser form and keeps the instance session`() {
        server.enqueue(
            MockResponse.Builder().code(302).addHeader("Location", "/orders")
                .addHeader("Set-Cookie", "_rupert_session=instance; path=/; HttpOnly").build()
        )
        server.enqueue(MockResponse.Builder().code(200).body("<html>Orders</html>").build())
        val link = WorkspaceLink(site, "ONE+TIME=", "https://pos.rupertpos.com")

        val session = NativeHttp.exchangeHandoff(link, "UA")

        val post = server.takeRequest()
        assertEquals("/instance/session", post.url.encodedPath)
        assertEquals("https://pos.rupertpos.com", post.headers["Origin"])
        assertEquals("handoff=ONE%2BTIME%3D", post.body!!.utf8())
        val follow = server.takeRequest()
        assertEquals("/orders", follow.url.encodedPath)
        assertTrue("the redirect carries the new session", follow.headers["Cookie"]!!.contains("_rupert_session=instance"))
        assertEquals("$site/orders", session.landing)
        assertTrue(session.cookies.single().header.startsWith("_rupert_session=instance"))
    }

    @Test fun `a refused handoff shows the instance's short message`() {
        server.enqueue(MockResponse.Builder().code(403).body("This sign-in link has expired.").build())
        try {
            NativeHttp.exchangeHandoff(WorkspaceLink(site, "x", "https://pos.rupertpos.com"), "UA")
            fail("expected a problem")
        } catch (problem: SignInProblem) {
            assertEquals("This sign-in link has expired.", problem.message)
        }
    }

    @Test fun `a server that serves the navigation rules is Rupert`() {
        server.enqueue(MockResponse.Builder().code(200).body("{\"settings\":{},\"rules\":[]}").build())
        assertEquals(NativeHttp.Probe.Rupert, NativeHttp.probe(site, "UA"))
        assertEquals("/native/android/path-configuration.json", server.takeRequest().url.encodedPath)
    }

    @Test fun `an older Rupert is found through the iPhone rules`() {
        server.enqueue(MockResponse.Builder().code(404).build())
        server.enqueue(MockResponse.Builder().code(200).body("{\"rules\":[]}").build())
        assertEquals(NativeHttp.Probe.Rupert, NativeHttp.probe(site, "UA"))
    }

    @Test fun `another website is not Rupert`() {
        server.enqueue(MockResponse.Builder().code(200).body("<html></html>").build())
        server.enqueue(MockResponse.Builder().code(404).build())
        assertTrue(NativeHttp.probe(site, "UA") is NativeHttp.Probe.Problem)
    }

    @Test fun `an unreachable server says so`() {
        server.close()
        val probe = NativeHttp.probe(site, "UA")
        assertTrue(probe is NativeHttp.Probe.Problem && probe.reason.startsWith("Rupert could not reach that server"))
    }
}
