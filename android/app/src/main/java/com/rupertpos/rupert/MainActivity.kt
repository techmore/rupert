package com.rupertpos.rupert

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import dev.hotwire.core.config.Hotwire
import dev.hotwire.navigation.activities.HotwireActivity
import dev.hotwire.navigation.navigator.Navigator
import dev.hotwire.navigation.navigator.NavigatorConfiguration
import dev.hotwire.navigation.tabs.HotwireBottomNavigationController
import dev.hotwire.navigation.tabs.HotwireBottomTab
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The one window: a tab bar where each tab keeps its own back stack of Rupert pages, on the
 * instance the app is pointed at (Instance.current). Also receives what comes from outside:
 * the Google sign-in answer, Rupert links (App Links) and launcher shortcuts.
 */
class MainActivity : HotwireActivity() {
    private lateinit var bottomNavigation: HotwireBottomNavigationController
    private val base = Instance.current

    /**
     * After a sign-in or handoff, Home starts on the landing page itself (the page Rupert chose),
     * instead of loading /login and then moving on. Read lazily: the intent exists only from onCreate.
     */
    private val tabs by lazy {
        val landing = intent.getStringExtra(EXTRA_LANDING)?.takeIf { InstanceAddress.originOf(it) == base }
        RupertTab.entries.map { tab ->
            val configuration = tab.configuration(base)
            HotwireBottomTab(
                title = getString(tab.title),
                iconResId = tab.icon,
                configuration = if (tab == RupertTab.HOME && landing != null) configuration.copy(startLocation = landing) else configuration,
            )
        }
    }

    /** A Rupert link to open once the Home tab is ready. */
    private var pendingHomeLocation: String? = null

    /** Whether the last page any tab finished was the sign-in page. A change makes other tabs stale. */
    private var onSignInPage: Boolean? = null
    private val staleTabs = mutableSetOf<String>()

    private val settings = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val data = result.data ?: return@registerForActivityResult
        when {
            data.getBooleanExtra(SettingsActivity.EXTRA_SERVER_CHANGED, false) -> restart(landing = null)
            data.getStringExtra(SettingsActivity.EXTRA_OPEN_URL) != null ->
                bottomNavigation.route(data.getStringExtra(SettingsActivity.EXTRA_OPEN_URL)!!)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        bottomNavigation = HotwireBottomNavigationController(
            activity = this,
            view = findViewById<BottomNavigationView>(R.id.bottom_nav),
            lazyLoadTabs = true,
        )
        bottomNavigation.load(tabs, selectedTabIndex = RupertTab.index(intent.getStringExtra(EXTRA_TAB)) ?: 0)
        bottomNavigation.setOnTabSelectedListener { _, tab -> refreshIfStale(tab.configuration.name) }

        if (savedInstanceState == null) handleViewIntent(intent)
    }

    override fun navigatorConfigurations(): List<NavigatorConfiguration> = tabs.map { it.configuration }

    override fun onNavigatorReady(navigator: Navigator) {
        super.onNavigatorReady(navigator)
        if (navigator.configuration.name == RupertTab.HOME.id) {
            pendingHomeLocation?.let { location ->
                pendingHomeLocation = null
                // The tab's first page is still being created: route once it is laid out.
                findViewById<View>(RupertTab.HOME.hostId).post { navigator.route(location) }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        RupertTab.index(intent.getStringExtra(EXTRA_TAB))?.let(bottomNavigation::selectTab)
        handleViewIntent(intent)
    }

    /** rupert://auth/google from the browser tab, or a Rupert https link. */
    private fun handleViewIntent(intent: Intent) {
        if (intent.action != Intent.ACTION_VIEW) return
        val url = intent.dataString ?: return
        when {
            GoogleCallback.isCallback(url) -> finishGoogleSignIn(url)
            Instance.isRupert(url) -> openFromLink(url)
        }
    }

    /** A Rupert link from outside the app: open it on Home, on the instance it belongs to. */
    private fun openFromLink(url: String) {
        bottomNavigation.selectTab(0)
        val home = delegate.currentNavigator
        if (home != null && home.isReady() && home.configuration.name == RupertTab.HOME.id) {
            home.route(url)
        } else {
            pendingHomeLocation = url
        }
    }

    fun startGoogleSignIn(link: String) {
        GoogleSignIn.start(this, link) { problem -> showProblem(R.string.google_sign_in, problem) }
    }

    private fun finishGoogleSignIn(callback: String) {
        when (val outcome = GoogleSignIn.finish(callback)) {
            is GoogleSignIn.Outcome.Redeem -> lifecycleScope.launch {
                try {
                    val session = withContext(Dispatchers.IO) {
                        NativeHttp.redeemGoogleCode(outcome.site, outcome.code, outcome.verifier, userAgent())
                    }
                    NativeHttp.install(session)
                    show(instance = InstanceAddress.originOf(session.landing) ?: Instance.current, landing = session.landing)
                } catch (error: Exception) {
                    showProblem(R.string.google_sign_in, error.message ?: getString(R.string.google_sign_in_failed))
                }
            }
            is GoogleSignIn.Outcome.Problem -> showProblem(R.string.google_sign_in, outcome.message)
            is GoogleSignIn.Outcome.Notice -> showProblem(R.string.workspace_request, outcome.message)
            GoogleSignIn.Outcome.NotStarted -> Unit
        }
    }

    private var handoffInFlight = false

    /** "Open my workspace" answered rupert://workspace?origin=…&handoff=…: sign in there natively. */
    fun openWorkspace(link: String) {
        if (handoffInFlight) return
        val workspace = WorkspaceLink.parse(link)
            ?: return showProblem(R.string.open_workspace, getString(R.string.workspace_link_incomplete))
        handoffInFlight = true
        lifecycleScope.launch {
            try {
                val session = withContext(Dispatchers.IO) { NativeHttp.exchangeHandoff(workspace, userAgent()) }
                NativeHttp.install(session)
                show(instance = workspace.origin, landing = session.landing)
            } catch (error: Exception) {
                showProblem(R.string.open_workspace, error.message ?: getString(R.string.workspace_failed))
            } finally {
                handoffInFlight = false
            }
        }
    }

    fun openSettings() {
        settings.launch(Intent(this, SettingsActivity::class.java))
    }

    /**
     * Point every tab at `instance` (after a sign-in or a workspace handoff) and open `landing` on
     * Home. Each tab starts over, since they all showed the sign-in page or the control plane.
     */
    private fun show(instance: String, landing: String) {
        Instance.setCurrent(instance)
        restart(landing.takeIf { InstanceAddress.pathOf(it) != "/" || it.contains('?') })
    }

    /** Starts the tabs over (new instance or server); the old stacks belong to the old site. */
    private fun restart(landing: String?) {
        RupertApplication.loadPathConfiguration(this)
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                .putExtra(EXTRA_LANDING, landing)
        )
        finish()
        overridePendingTransition(0, 0)
    }

    /**
     * Signing in or out in one tab leaves the others on the old state (a sign-in page, or business
     * pages after signing out). Mark them, and start each over when it is next opened.
     */
    fun visitCompleted(navigator: Navigator, location: String) {
        val tab = navigator.configuration.name
        val signIn = InstanceAddress.pathOf(location) == "/login"
        val previous = onSignInPage
        onSignInPage = signIn
        if (previous != null && previous != signIn) {
            staleTabs += RupertTab.entries.map { it.id }.filter { it != tab }
            // Just signed in: start this tab over, so the signed-in page is its first page (with
            // the App settings button) instead of sitting on top of the sign-in form.
            if (previous && !navigator.isAtStartDestination()) navigator.reset()
        }
    }

    private fun refreshIfStale(tab: String) {
        if (staleTabs.remove(tab)) delegate.currentNavigator?.reset()
    }

    private fun userAgent(): String = Hotwire.config.userAgentWithWebViewDefault(this)

    private fun showProblem(title: Int, message: String) {
        if (isFinishing) return
        MaterialAlertDialogBuilder(this)
            .setTitle(title)
            .setMessage(message)
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }

    companion object {
        const val EXTRA_TAB = "com.rupertpos.rupert.TAB"
        private const val EXTRA_LANDING = "com.rupertpos.rupert.LANDING"

        fun tabIntent(context: Context, tab: RupertTab) =
            Intent(context, MainActivity::class.java).putExtra(EXTRA_TAB, tab.id)
    }
}
