package com.rupertpos.rupert

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner

/**
 * Optional lock for the app (fingerprint, face or the phone's screen lock): Rupert holds sales,
 * payroll and bookkeeping, and phones get handed around a shop. Turned on in App settings.
 *
 * The app locks whenever it leaves the screen, except for the screens it opens itself (the Google
 * sign-in tab, the barcode scanner, the camera or file picker). While locked, a cover hides every
 * page, and the recent-apps screen shows no snapshot of Rupert.
 */
object AppLock : Application.ActivityLifecycleCallbacks, DefaultLifecycleObserver {
    private const val ENABLED_KEY = "requireDeviceAuthentication"

    private lateinit var preferences: SharedPreferences
    private var locked = false
    private var authenticating = false
    /**
     * When the app last opened another app's screen (0: none pending). The next time the app leaves
     * the screen is for that, so it does not lock. Cleared when the app comes back to the front
     * without having left, and after a minute at most, so a failed launch cannot keep the lock off.
     */
    private var externalScreenAt = 0L
    private var pausedSinceExternalScreen = false
    /** Ask on its own once per lock; after a cancel the cover's Unlock button asks again. */
    private var promptOnResume = false

    fun init(application: Application) {
        preferences = application.getSharedPreferences("rupert.lock", Context.MODE_PRIVATE)
        locked = isEnabled
        promptOnResume = locked
        application.registerActivityLifecycleCallbacks(this)
        ProcessLifecycleOwner.get().lifecycle.addObserver(this)
    }

    var isEnabled: Boolean
        get() = preferences.getBoolean(ENABLED_KEY, false)
        set(value) {
            preferences.edit { putBoolean(ENABLED_KEY, value) }
        }

    /** Biometrics (strong where the API allows mixing it with the screen lock) or the screen lock. */
    val authenticators: Int
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) BIOMETRIC_STRONG or DEVICE_CREDENTIAL
        else BIOMETRIC_WEAK or DEVICE_CREDENTIAL

    /** False when the phone has no screen lock: there is nothing to check against. */
    fun isAvailable(context: Context): Boolean =
        BiometricManager.from(context).canAuthenticate(authenticators) == BiometricManager.BIOMETRIC_SUCCESS

    /** The app is about to show a screen of another app (sign-in tab, scanner, camera, files). */
    fun allowExternalScreen() {
        externalScreenAt = SystemClock.elapsedRealtime()
        pausedSinceExternalScreen = false
    }

    private val leftForExternalScreen: Boolean
        get() = externalScreenAt != 0L && SystemClock.elapsedRealtime() - externalScreenAt < 60_000

    /** Asks once, for turning the lock on in settings. */
    fun confirm(activity: FragmentActivity, title: String, done: (Boolean) -> Unit) {
        val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = done(true)
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) = done(false)
        })
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setAllowedAuthenticators(authenticators)
            .build()
        prompt.authenticate(info)
    }

    // The whole app went to the background.
    override fun onStop(owner: LifecycleOwner) {
        if (isEnabled && !leftForExternalScreen) {
            locked = true
            promptOnResume = true
        }
        externalScreenAt = 0L
    }

    override fun onStart(owner: LifecycleOwner) {
        externalScreenAt = 0L
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        protectRecents(activity)
    }

    override fun onActivityResumed(activity: Activity) {
        // Back in front without the app having left (a dialog-like screen): the allowance is spent.
        if (pausedSinceExternalScreen) {
            externalScreenAt = 0L
            pausedSinceExternalScreen = false
        }
        protectRecents(activity)
        if (locked) {
            showCover(activity)
            if (promptOnResume) {
                promptOnResume = false
                unlock(activity)
            }
        } else {
            removeCover(activity)
        }
    }

    override fun onActivityStopped(activity: Activity) {
        if (locked) showCover(activity)
    }

    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityPaused(activity: Activity) {
        if (externalScreenAt != 0L) pausedSinceExternalScreen = true
    }
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}

    /** No business data in the recent-apps snapshot while the lock is on. */
    fun protectRecents(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.setRecentsScreenshotEnabled(!isEnabled)
        } else if (isEnabled) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    private fun unlock(activity: Activity) {
        if (authenticating) return
        val fragmentActivity = activity as? FragmentActivity ?: return
        if (!isAvailable(activity)) {
            // The screen lock was removed from the phone: nothing left to check against.
            finishUnlock(activity)
            return
        }
        authenticating = true
        // The screen lock may open its own screen (PIN pad on older Android): not a reason to lock again.
        allowExternalScreen()
        confirm(fragmentActivity, activity.getString(R.string.lock_prompt_title)) { ok ->
            authenticating = false
            externalScreenAt = 0L
            if (ok) finishUnlock(activity)
        }
    }

    private fun finishUnlock(activity: Activity) {
        locked = false
        val cover = activity.findViewById<View>(R.id.lock_cover) ?: return
        cover.animate().alpha(0f).setDuration(200).withEndAction { removeCover(activity) }.start()
    }

    private fun showCover(activity: Activity) {
        val content = activity.findViewById<ViewGroup>(android.R.id.content) ?: return
        if (content.findViewById<View>(R.id.lock_cover) != null) return
        val cover = LayoutInflater.from(activity).inflate(R.layout.view_lock_cover, content, false)
        cover.findViewById<View>(R.id.lock_unlock).setOnClickListener { unlock(activity) }
        content.addView(cover)
        // Screen readers must not read the pages under the cover either.
        for (index in 0 until content.childCount) {
            val child = content.getChildAt(index)
            if (child !== cover) child.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        }
        cover.requestFocus()
    }

    private fun removeCover(activity: Activity) {
        val content = activity.findViewById<ViewGroup>(android.R.id.content) ?: return
        content.findViewById<View>(R.id.lock_cover)?.let(content::removeView)
        for (index in 0 until content.childCount) {
            content.getChildAt(index).importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
        }
    }
}
