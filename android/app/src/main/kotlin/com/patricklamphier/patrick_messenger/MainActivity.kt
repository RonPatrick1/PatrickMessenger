package com.patricklamphier.patrick_messenger

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.mediadevkit.fvp.FvpPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private data class PendingMediaSave(
        val bytes: ByteArray?,
        val sourcePath: String?,
        val name: String,
        val mimeType: String,
        val isVideo: Boolean,
        val result: MethodChannel.Result,
    )

    private var pendingMediaSave: PendingMediaSave? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.remove(FvpPlugin::class.java)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.patricklamphier.patrickMessenger/ocr",
        ).setMethodCallHandler { call, result ->
            if (call.method != "recognize") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val bytes = call.argument<ByteArray>("bytes")
            val bitmap = bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
            if (bitmap == null) {
                result.error("invalid_image", "The image could not be decoded.", null)
                return@setMethodCallHandler
            }
            val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            recognizer.process(InputImage.fromBitmap(bitmap, 0))
                .addOnSuccessListener { text -> result.success(text.text) }
                .addOnFailureListener { error ->
                    result.error("ocr_failed", error.localizedMessage, null)
                }
                .addOnCompleteListener { recognizer.close() }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.patricklamphier.patrickMessenger/media_save",
        ).setMethodCallHandler { call, result ->
            if (call.method != "saveImage" && call.method != "saveVideo") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val isVideo = call.method == "saveVideo"
            val bytes = call.argument<ByteArray>("bytes")
            val sourcePath = call.argument<String>("path")
            val name = call.argument<String>("name")
            val mimeType = call.argument<String>("mimeType")
            if (
                (isVideo && sourcePath.isNullOrBlank()) ||
                    (!isVideo && bytes == null) ||
                    name.isNullOrBlank() ||
                    mimeType.isNullOrBlank()
            ) {
                result.error("invalid_media", "The media file is invalid.", null)
                return@setMethodCallHandler
            }
            val pending = PendingMediaSave(
                bytes = bytes,
                sourcePath = sourcePath,
                name = name,
                mimeType = mimeType,
                isVideo = isVideo,
                result = result,
            )
            if (
                Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
                    ContextCompat.checkSelfPermission(
                        this,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE,
                    ) != PackageManager.PERMISSION_GRANTED
            ) {
                if (pendingMediaSave != null) {
                    result.error("save_in_progress", "Another file is being saved.", null)
                    return@setMethodCallHandler
                }
                pendingMediaSave = pending
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    MEDIA_SAVE_PERMISSION_REQUEST,
                )
            } else {
                saveMedia(pending)
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.patricklamphier.patrickMessenger/car_reply",
        ).setMethodCallHandler { call, result ->
            if (call.method != "registerCallback") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val handle = call.argument<Number>("handle")?.toLong()
            if (handle == null) {
                result.error("invalid_handle", "No callback handle was provided.", null)
                return@setMethodCallHandler
            }
            getSharedPreferences(CarReplyService.CAR_REPLY_PREFS, MODE_PRIVATE)
                .edit()
                .putLong(CarReplyService.CALLBACK_HANDLE_KEY, handle)
                .apply()
            result.success(null)
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.patricklamphier.patrickMessenger/car_notification",
        ).setMethodCallHandler { call, result ->
            if (call.method != "show") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val roomId = call.argument<String>("roomId")
            val senderId = call.argument<String>("senderId")
            val senderName = call.argument<String>("senderName")
            val conversationTitle = call.argument<String>("conversationTitle")
            val body = call.argument<String>("body")
            val isGroupConversation = call.argument<Boolean>("isGroupConversation") ?: false
            val phoneNotificationId = call.argument<Number>("notificationId")?.toInt() ?: -1
            if (
                roomId == null || senderId == null || senderName == null ||
                    conversationTitle == null || body == null
            ) {
                result.error("invalid_arguments", "Missing car notification fields.", null)
                return@setMethodCallHandler
            }
            CarMessagingNotificationBuilder.show(
                context = this,
                roomId = roomId,
                phoneNotificationId = phoneNotificationId,
                senderId = senderId,
                senderName = senderName,
                conversationTitle = conversationTitle,
                isGroupConversation = isGroupConversation,
                body = body,
            )
            result.success(null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MEDIA_SAVE_PERMISSION_REQUEST) return
        val pending = pendingMediaSave ?: return
        pendingMediaSave = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            saveMedia(pending)
        } else {
            pending.result.error(
                "media_permission_denied",
                "Media storage permission was denied.",
                null,
            )
        }
    }

    private fun saveMedia(pending: PendingMediaSave) {
        Thread {
            try {
                val savedLocation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    saveWithMediaStore(pending)
                } else {
                    saveLegacyMedia(pending)
                }
                runOnUiThread { pending.result.success(savedLocation) }
            } catch (error: Exception) {
                runOnUiThread {
                    pending.result.error(
                        "media_save_failed",
                        error.localizedMessage ?: "The media file could not be saved.",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun saveWithMediaStore(pending: PendingMediaSave): String {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, safeFileName(pending.name))
            put(MediaStore.MediaColumns.MIME_TYPE, pending.mimeType)
            put(
                MediaStore.MediaColumns.RELATIVE_PATH,
                "${if (pending.isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES}/Patrick Messenger",
            )
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = if (pending.isVideo) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val uri = contentResolver.insert(
            collection,
            values,
        ) ?: throw IllegalStateException("Android could not create the media file.")
        try {
            contentResolver.openOutputStream(uri)?.use { output ->
                if (pending.sourcePath != null) {
                    File(pending.sourcePath).inputStream().use { input -> input.copyTo(output) }
                } else {
                    output.write(pending.bytes!!)
                }
            } ?: throw IllegalStateException("Android could not open the media file.")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        } catch (error: Exception) {
            contentResolver.delete(uri, null, null)
            throw error
        }
    }

    @Suppress("DEPRECATION")
    private fun saveLegacyMedia(pending: PendingMediaSave): String {
        val directory = File(
            Environment.getExternalStoragePublicDirectory(
                if (pending.isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES,
            ),
            "Patrick Messenger",
        )
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Android could not create the media folder.")
        }
        val desired = File(directory, safeFileName(pending.name))
        val output = uniqueFile(desired)
        if (pending.sourcePath != null) {
            File(pending.sourcePath).inputStream().use { input ->
                FileOutputStream(output).use { target -> input.copyTo(target) }
            }
        } else {
            FileOutputStream(output).use { it.write(pending.bytes!!) }
        }
        MediaScannerConnection.scanFile(
            this,
            arrayOf(output.absolutePath),
            arrayOf(pending.mimeType),
            null,
        )
        return output.absolutePath
    }

    private fun safeFileName(name: String): String =
        File(name).name.replace(Regex("[^A-Za-z0-9._ -]"), "_")

    private fun uniqueFile(desired: File): File {
        if (!desired.exists()) return desired
        val extension = desired.extension.let { if (it.isEmpty()) "" else ".$it" }
        val base = desired.name.removeSuffix(extension)
        var counter = 2
        while (true) {
            val candidate = File(desired.parentFile, "$base ($counter)$extension")
            if (!candidate.exists()) return candidate
            counter++
        }
    }

    private companion object {
        const val MEDIA_SAVE_PERMISSION_REQUEST = 7341
    }
}
