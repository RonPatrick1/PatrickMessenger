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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private data class PendingImageSave(
        val bytes: ByteArray,
        val name: String,
        val mimeType: String,
        val result: MethodChannel.Result,
    )

    private var pendingImageSave: PendingImageSave? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
            if (call.method != "saveImage") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val bytes = call.argument<ByteArray>("bytes")
            val name = call.argument<String>("name")
            val mimeType = call.argument<String>("mimeType")
            if (bytes == null || name.isNullOrBlank() || mimeType.isNullOrBlank()) {
                result.error("invalid_picture", "The picture is invalid.", null)
                return@setMethodCallHandler
            }
            val pending = PendingImageSave(bytes, name, mimeType, result)
            if (
                Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
                    ContextCompat.checkSelfPermission(
                        this,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE,
                    ) != PackageManager.PERMISSION_GRANTED
            ) {
                if (pendingImageSave != null) {
                    result.error("save_in_progress", "Another picture is being saved.", null)
                    return@setMethodCallHandler
                }
                pendingImageSave = pending
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    MEDIA_SAVE_PERMISSION_REQUEST,
                )
            } else {
                saveImage(pending)
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MEDIA_SAVE_PERMISSION_REQUEST) return
        val pending = pendingImageSave ?: return
        pendingImageSave = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            saveImage(pending)
        } else {
            pending.result.error(
                "photo_permission_denied",
                "Photo storage permission was denied.",
                null,
            )
        }
    }

    private fun saveImage(pending: PendingImageSave) {
        Thread {
            try {
                val savedLocation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    saveImageWithMediaStore(pending)
                } else {
                    saveLegacyImage(pending)
                }
                runOnUiThread { pending.result.success(savedLocation) }
            } catch (error: Exception) {
                runOnUiThread {
                    pending.result.error(
                        "picture_save_failed",
                        error.localizedMessage ?: "The picture could not be saved.",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun saveImageWithMediaStore(pending: PendingImageSave): String {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, safeFileName(pending.name))
            put(MediaStore.Images.Media.MIME_TYPE, pending.mimeType)
            put(
                MediaStore.Images.Media.RELATIVE_PATH,
                "${Environment.DIRECTORY_PICTURES}/Patrick Messenger",
            )
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
            values,
        ) ?: throw IllegalStateException("Android could not create the picture.")
        try {
            contentResolver.openOutputStream(uri)?.use { output ->
                output.write(pending.bytes)
            } ?: throw IllegalStateException("Android could not open the picture.")
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        } catch (error: Exception) {
            contentResolver.delete(uri, null, null)
            throw error
        }
    }

    @Suppress("DEPRECATION")
    private fun saveLegacyImage(pending: PendingImageSave): String {
        val directory = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            "Patrick Messenger",
        )
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Android could not create the pictures folder.")
        }
        val desired = File(directory, safeFileName(pending.name))
        val output = uniqueFile(desired)
        FileOutputStream(output).use { it.write(pending.bytes) }
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
