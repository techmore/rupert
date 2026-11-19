package com.rupertpos.rupert

import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.action.ViewActions.closeSoftKeyboard
import androidx.test.espresso.action.ViewActions.replaceText
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.hasDescendant
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
import androidx.test.espresso.matcher.ViewMatchers.withId
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.hamcrest.Matchers.containsString
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Starts the real app on a device or emulator: the tab bar, App settings and the server picker's
 * address check. It needs no Rupert server (the pages may fail to load; the native screens do not).
 *   ./gradlew connectedDebugAndroidTest
 */
@RunWith(AndroidJUnit4::class)
class SmokeTest {
    @get:Rule val activity = ActivityScenarioRule(MainActivity::class.java)

    @Test fun tabsSettingsAndServerCheck() {
        onView(withId(R.id.bottom_nav)).check(matches(isDisplayed()))
        listOf("Home", "Team Chat", "Ask Rupert", "Notifications", "Search").forEach { title ->
            onView(withId(R.id.bottom_nav)).check(matches(hasDescendant(withText(title))))
        }

        onView(withContentDescription("App settings")).perform(click())
        onView(withText("Require screen lock")).check(matches(isDisplayed()))
        onView(withText("Rupert server")).perform(click())

        onView(withId(R.id.server_input)).perform(replaceText("http://rupert.example.com"), closeSoftKeyboard())
        onView(withId(R.id.server_connect)).perform(click())
        onView(withText(containsString("Rupert needs https://"))).check(matches(isDisplayed()))
    }
}
