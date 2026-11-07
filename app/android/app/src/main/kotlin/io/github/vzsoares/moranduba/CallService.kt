package io.github.vzsoares.moranduba

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps the mic and camera while a call runs in the background. While
 * sharing it also carries the mediaProjection type, which Android 14 wants
 * running between the user's consent and the start of the capture.
 */
class CallService : Service() {
    companion object {
        private const val CHANNEL = "calls"
        private const val NOTIFICATION = 1
        private const val SHARING = "sharing"

        fun update(context: Context, sharing: Boolean) {
            val intent = Intent(context, CallService::class.java).putExtra(SHARING, sharing)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val sharing = intent?.getBooleanExtra(SHARING, false) == true
        try {
            val notification = notification(sharing)
            val types = types(sharing)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && types != 0) {
                startForeground(NOTIFICATION, notification, types)
            } else {
                startForeground(NOTIFICATION, notification)
            }
        } catch (e: RuntimeException) {
            Log.w("CallService", "cannot run in the foreground", e)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun granted(permission: String) =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun types(sharing: Boolean): Int {
        var types = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (granted(Manifest.permission.RECORD_AUDIO)) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            if (granted(Manifest.permission.CAMERA)) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
        }
        if (sharing && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        }
        return types
    }

    private fun notification(sharing: Boolean): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "Calls", NotificationManager.IMPORTANCE_LOW),
            )
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return builder
            .setContentTitle("Moranduba call")
            .setContentText(if (sharing) "Sharing your screen" else "In a call")
            .setSmallIcon(android.R.drawable.sym_action_call)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }
}
