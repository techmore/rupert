package com.rupertpos.rupert

import android.os.Build
import android.view.HapticFeedbackConstants
import android.webkit.WebView
import androidx.appcompat.app.AppCompatActivity
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.mlkit.common.MlKitException
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import org.json.JSONArray

/**
 * Reads barcodes with the camera for Rupert's inventory scan page (/inventory_counts/:id/scan).
 *
 * The page shows "Scan with camera" when the `rupertScanner` listener exists
 * (inventory_count_scanner_controller.js). The app opens Google's code scanner, which runs in
 * Google Play services: it needs no camera permission in this app and sends no images to Rupert.
 * The code goes back to the page as a `rupert:scanned` event, which saves it.
 */
object BarcodeScanner {
    fun scan(webView: WebView) {
        val activity = webView.context as? AppCompatActivity ?: return
        if (GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(activity) != ConnectionResult.SUCCESS) {
            unavailable(activity, "This phone has no Google Play services, which Rupert uses to read barcodes. Type the code or use a barcode scanner instead.")
            return
        }

        val options = GmsBarcodeScannerOptions.Builder()
            .enableAutoZoom()
            .build()
        // The scanner is its own screen: coming back from it must not lock the app.
        AppLock.allowExternalScreen()
        GmsBarcodeScanning.getClient(activity, options).startScan()
            .addOnSuccessListener { barcode ->
                val code = barcode.rawValue?.trim().orEmpty()
                if (code.isEmpty()) return@addOnSuccessListener
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    webView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                }
                webView.evaluateJavascript(scannedScript(code), null)
            }
            .addOnFailureListener { error ->
                val message = if ((error as? MlKitException)?.errorCode == MlKitException.UNAVAILABLE) {
                    // First use on this phone: Play services fetches the scanner once, in the background.
                    "Google Play services is still getting the barcode scanner ready on this phone. Try again in a minute, or type the code."
                } else {
                    "The camera scanner did not start (${error.message ?: "unknown reason"}). Type the code or use a barcode scanner instead."
                }
                unavailable(activity, message)
            }
    }

    /** The JavaScript that hands `code` to the page, with the code safely quoted. */
    fun scannedScript(code: String): String {
        val detail = JSONArray().put(code).toString()
        return "window.dispatchEvent(new CustomEvent('rupert:scanned', { detail: $detail[0] }))"
    }

    private fun unavailable(activity: AppCompatActivity, message: String) {
        if (activity.isFinishing) return
        MaterialAlertDialogBuilder(activity)
            .setTitle(R.string.scanner_unavailable_title)
            .setMessage(message)
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }
}
