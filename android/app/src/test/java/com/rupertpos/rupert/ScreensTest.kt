package com.rupertpos.rupert

import android.app.Activity
import android.view.View
import android.widget.TextView
import androidx.test.core.app.ActivityScenario
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.textfield.TextInputLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = TestApplication::class)
class ScreensTest {
    @Test fun `the tab bar has the iPhone app's five tabs`() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val menu = activity.findViewById<BottomNavigationView>(R.id.bottom_nav).menu
                assertEquals(listOf("Home", "Team Chat", "Ask Rupert", "Notifications", "Search"),
                    (0 until menu.size()).map { menu.getItem(it).title.toString() })
                assertEquals(View.VISIBLE, activity.findViewById<View>(R.id.tab_home).visibility)
                assertEquals(View.GONE, activity.findViewById<View>(R.id.tab_chat).visibility)
            }
        }
    }

    @Test fun `settings show where the app is connected and its version`() {
        ActivityScenario.launch(SettingsActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                assertEquals("pos.rupertpos.com", activity.findViewById<TextView>(R.id.settings_connected_to).text.toString())
                assertEquals(Instance.appVersion, activity.findViewById<TextView>(R.id.settings_version).text.toString())
                // The lock is off until someone turns it on (and proves they can unlock).
                assertFalse(activity.findViewById<com.google.android.material.materialswitch.MaterialSwitch>(R.id.settings_lock).isChecked)
            }
        }
    }

    @Test fun `help links open in the app's current tab`() {
        ActivityScenario.launchActivityForResult(SettingsActivity::class.java).use { scenario ->
            scenario.onActivity { activity -> activity.findViewById<View>(R.id.settings_privacy).performClick() }
            assertEquals(Activity.RESULT_OK, scenario.result.resultCode)
            assertEquals("https://pos.rupertpos.com/privacy", scenario.result.resultData.getStringExtra(SettingsActivity.EXTRA_OPEN_URL))
        }
    }

    @Test fun `the server screen refuses an unencrypted public address before connecting`() {
        ActivityScenario.launch(ServerActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.findViewById<TextView>(R.id.server_input).text = "http://rupert.example.com"
                activity.findViewById<View>(R.id.server_connect).performClick()
                val error = activity.findViewById<TextInputLayout>(R.id.server_field).error
                assertNotNull(error)
                assertTrue(error.toString().startsWith("Rupert needs https://"))
            }
        }
    }
}
