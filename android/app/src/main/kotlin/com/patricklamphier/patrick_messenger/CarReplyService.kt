package com.patricklamphier.patrick_messenger

import android.app.IntentService
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Handles the reply/mark-as-read actions on the Android Auto messaging
 * notification without requiring the app's own UI process to be alive.
 * The system briefly allowlists this app to start a background service
 * from a notification action (documented Android Auto behavior for
 * exactly this case), so a plain [IntentService] is sufficient here.
 *
 * Because the app may be fully killed, this spins up a fresh, headless
 * Flutter engine running only the `carReplyDispatcher` entry point
 * (lib/notifications/car_reply_dispatcher.dart, registered by
 * `CarReplyRegistration` while the app was last running), which reconnects
 * to the already-logged-in Matrix session and performs the actual
 * send/mark-read. All Flutter engine APIs must run on
 * the main thread; this service's own worker thread blocks on a latch
 * while that happens.
 */
class CarReplyService : IntentService("CarReplyService") {
    override fun onHandleIntent(intent: Intent?) {
        intent ?: return
        val roomId = intent.getStringExtra(
            CarMessagingNotificationBuilder.EXTRA_ROOM_ID,
        ) ?: return
        val phoneNotificationId = intent.getIntExtra(
            CarMessagingNotificationBuilder.EXTRA_PHONE_NOTIFICATION_ID,
            -1,
        )

        val succeeded = when (intent.action) {
            ACTION_REPLY -> {
                val replyText = RemoteInput.getResultsFromIntent(intent)
                    ?.getCharSequence(CarMessagingNotificationBuilder.REMOTE_INPUT_RESULT_KEY)
                    ?.toString()
                    ?.trim()
                if (replyText.isNullOrEmpty()) {
                    false
                } else {
                    invokeHeadlessDart(
                        "handleReply",
                        mapOf("roomId" to roomId, "replyText" to replyText),
                    )
                }
            }
            ACTION_MARK_READ -> {
                invokeHeadlessDart("handleMarkRead", mapOf("roomId" to roomId))
            }
            else -> false
        }

        if (succeeded) {
            val manager = NotificationManagerCompat.from(this)
            manager.cancel(CarMessagingNotificationBuilder.carNotificationId(roomId))
            if (phoneNotificationId != -1) {
                manager.cancel(phoneNotificationId)
            }
        }
    }

    private fun invokeHeadlessDart(method: String, arguments: Map<String, Any?>): Boolean {
        val handle = getSharedPreferences(CAR_REPLY_PREFS, MODE_PRIVATE)
            .getLong(CALLBACK_HANDLE_KEY, -1L)
        if (handle == -1L) return false
        val callbackInfo = FlutterCallbackInformation.lookupCallbackInformation(handle)
            ?: return false

        val latch = CountDownLatch(1)
        var success = false
        val mainHandler = Handler(Looper.getMainLooper())

        mainHandler.post {
            val engine = FlutterEngine(applicationContext)
            val loader = FlutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)

            val dartCallback = DartExecutor.DartCallback(
                assets,
                loader.findAppBundlePath(),
                callbackInfo,
            )
            engine.dartExecutor.executeDartCallback(dartCallback)

            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, ISOLATE_CHANNEL)
            channel.setMethodCallHandler { call, result ->
                if (call.method != "initialized") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                result.success(null)
                channel.invokeMethod(
                    method,
                    arguments,
                    object : MethodChannel.Result {
                        override fun success(resultValue: Any?) {
                            success = resultValue == true
                            engine.destroy()
                            latch.countDown()
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?,
                        ) {
                            engine.destroy()
                            latch.countDown()
                        }

                        override fun notImplemented() {
                            engine.destroy()
                            latch.countDown()
                        }
                    },
                )
            }
        }

        latch.await(25, TimeUnit.SECONDS)
        return success
    }

    companion object {
        const val ACTION_REPLY = "com.patricklamphier.patrick_messenger.CAR_REPLY"
        const val ACTION_MARK_READ = "com.patricklamphier.patrick_messenger.CAR_MARK_READ"
        const val CAR_REPLY_PREFS = "car_reply_prefs"
        const val CALLBACK_HANDLE_KEY = "callback_handle"
        const val ISOLATE_CHANNEL = "com.patricklamphier.patrickMessenger/car_reply_isolate"
    }
}
