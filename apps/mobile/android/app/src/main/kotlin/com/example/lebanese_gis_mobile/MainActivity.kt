package com.example.lebanese_gis_mobile

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URLConnection

class MainActivity : FlutterActivity() {
    private val locationChannelName = "lb.gov.gis_collector/location"
    private val exportFilesChannelName = "lb.gov.gis_collector/export_files"
    private val locationPermissionRequestCode = 8124
    private var pendingLocationResult: MethodChannel.Result? = null
    private var pendingLocationListener: LocationListener? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            locationChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getCurrentLocation" -> handleGetCurrentLocation(result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            exportFilesChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openFile" -> handleOpenFile(call.arguments as? Map<*, *>, result)
                "shareFile" -> handleShareFile(call.arguments as? Map<*, *>, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun handleGetCurrentLocation(result: MethodChannel.Result) {
        if (pendingLocationResult != null) {
            result.error(
                "LOCATION_BUSY",
                "Location is already being requested. Please wait a moment.",
                null
            )
            return
        }

        val locationManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (locationManager == null || !isLocationServiceEnabled(locationManager)) {
            result.error(
                "LOCATION_SERVICE_DISABLED",
                "Location services are turned off on this device.",
                null
            )
            return
        }

        if (!hasLocationPermission()) {
            pendingLocationResult = result
            requestPermissions(
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION
                ),
                locationPermissionRequestCode
            )
            return
        }

        fetchCurrentLocation(locationManager, result)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode != locationPermissionRequestCode) {
            return
        }

        val result = pendingLocationResult ?: return
        pendingLocationResult = null

        val granted = grantResults.any { it == PackageManager.PERMISSION_GRANTED }
        if (!granted) {
            val deniedForever = permissions.any { permission ->
                !shouldShowRequestPermissionRationale(permission)
            }
            result.error(
                if (deniedForever) {
                    "LOCATION_PERMISSION_DENIED_FOREVER"
                } else {
                    "LOCATION_PERMISSION_DENIED"
                },
                if (deniedForever) {
                    "Location permission has been permanently denied for this app."
                } else {
                    "Location permission is needed to center the map on your position."
                },
                null
            )
            return
        }

        val locationManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (locationManager == null || !isLocationServiceEnabled(locationManager)) {
            result.error(
                "LOCATION_SERVICE_DISABLED",
                "Location services are turned off on this device.",
                null
            )
            return
        }

        fetchCurrentLocation(locationManager, result)
    }

    private fun hasLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_COARSE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
    }

    private fun isLocationServiceEnabled(locationManager: LocationManager): Boolean {
        return locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
            locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }

    @SuppressLint("MissingPermission")
    private fun fetchCurrentLocation(
        locationManager: LocationManager,
        result: MethodChannel.Result
    ) {
        val providers = buildList {
            if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                add(LocationManager.GPS_PROVIDER)
            }
            if (locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                add(LocationManager.NETWORK_PROVIDER)
            }
        }

        if (providers.isEmpty()) {
            result.error(
                "LOCATION_SERVICE_DISABLED",
                "Location services are turned off on this device.",
                null
            )
            return
        }

        val recentLastKnown = providers
            .mapNotNull { provider ->
                runCatching { locationManager.getLastKnownLocation(provider) }.getOrNull()
            }
            .maxByOrNull { location -> location.time }

        if (recentLastKnown != null && System.currentTimeMillis() - recentLastKnown.time <= 5 * 60 * 1000) {
            result.success(locationPayload(recentLastKnown))
            return
        }

        pendingLocationResult = result

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            locationManager.getCurrentLocation(
                providers.first(),
                null,
                mainExecutor
            ) { location ->
                val callback = pendingLocationResult ?: return@getCurrentLocation
                pendingLocationResult = null
                if (location == null) {
                    callback.error(
                        "LOCATION_UNAVAILABLE",
                        "Current location is unavailable right now.",
                        null
                    )
                } else {
                    callback.success(locationPayload(location))
                }
            }
            return
        }

        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                cleanupPendingLocationListener(locationManager)
                val callback = pendingLocationResult ?: return
                pendingLocationResult = null
                callback.success(locationPayload(location))
            }

            override fun onProviderDisabled(provider: String) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        }

        pendingLocationListener = listener
        locationManager.requestSingleUpdate(providers.first(), listener, Looper.getMainLooper())
        mainHandler.postDelayed({
            if (pendingLocationResult == null) {
                return@postDelayed
            }
            cleanupPendingLocationListener(locationManager)
            val callback = pendingLocationResult
            pendingLocationResult = null
            callback?.error(
                "LOCATION_UNAVAILABLE",
                "Current location is unavailable right now.",
                null
            )
        }, 12000)
    }

    private fun cleanupPendingLocationListener(locationManager: LocationManager) {
        mainHandler.removeCallbacksAndMessages(null)
        pendingLocationListener?.let { listener ->
            locationManager.removeUpdates(listener)
        }
        pendingLocationListener = null
    }

    private fun handleOpenFile(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val file = resolveExportFile(arguments, result) ?: return
        val uri = exportFileUri(file)
        val mimeType = URLConnection.guessContentTypeFromName(file.name) ?: "application/zip"
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        if (intent.resolveActivity(packageManager) == null) {
            result.error(
                "NO_APP_AVAILABLE",
                "No app on this device can open the exported file.",
                null
            )
            return
        }

        startActivity(intent)
        result.success(null)
    }

    private fun handleShareFile(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val file = resolveExportFile(arguments, result) ?: return
        val uri = exportFileUri(file)
        val mimeType = URLConnection.guessContentTypeFromName(file.name) ?: "application/zip"
        val subject = arguments?.get("subject") as? String
        val text = arguments?.get("text") as? String

        val shareIntent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            if (!subject.isNullOrBlank()) {
                putExtra(Intent.EXTRA_SUBJECT, subject)
            }
            if (!text.isNullOrBlank()) {
                putExtra(Intent.EXTRA_TEXT, text)
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        val chooser = Intent.createChooser(shareIntent, "Share export").apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(chooser)
        result.success(null)
    }

    private fun resolveExportFile(
        arguments: Map<*, *>?,
        result: MethodChannel.Result
    ): File? {
        val path = (arguments?.get("path") as? String)?.trim()
        if (path.isNullOrEmpty()) {
            result.error("MISSING_PATH", "Export file path is missing.", null)
            return null
        }

        val file = File(path)
        if (!file.exists()) {
            result.error(
                "FILE_NOT_FOUND",
                "The downloaded export is no longer available on this device.",
                null
            )
            return null
        }

        return file
    }

    private fun exportFileUri(file: File) =
        FileProvider.getUriForFile(this, "$packageName.fileprovider", file)

    private fun locationPayload(location: Location): Map<String, Any?> {
        return mapOf(
            "latitude" to location.latitude,
            "longitude" to location.longitude,
            "accuracyMeters" to if (location.hasAccuracy()) location.accuracy.toDouble() else null
        )
    }

    override fun onDestroy() {
        val locationManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (locationManager != null) {
            cleanupPendingLocationListener(locationManager)
        }
        pendingLocationResult = null
        super.onDestroy()
    }
}
