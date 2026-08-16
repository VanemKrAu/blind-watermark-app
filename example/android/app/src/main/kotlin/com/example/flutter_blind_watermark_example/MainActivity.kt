package com.example.flutter_blind_watermark_example

import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.PrintWriter
import java.io.StringWriter

/**
 * WAM inference moved to the FFI library (src/wam_ort.cpp) calling the ORT C
 * API directly: the previous ai.onnxruntime Java/JNI bridge aborted with
 * SIGABRT inside sess.run on Android 16 (ART JNI fatal). This file now only
 * handles: image picking (zero disk writes), model extraction to filesDir,
 * crash capture/reporting, and .nomedia guards.
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "wam"
        private const val PICK_IMAGE_REQ = 0x4147 // "AG"
    }

    private var pendingPickResult: MethodChannel.Result? = null
    private var wamChannel: MethodChannel? = null
    private var dartReadyFlag = false
    private var reportShownThisProcess = false

    /**
     * Captures uncaught Java/Kotlin exceptions into filesDir/crash.txt, then
     * re-raises so the crash behavior is unchanged. The native side
     * (blind_watermark_ffi) writes NATIVE CRASH markers into the same file
     * via its own signal handlers; showCrashReportIfAny surfaces the report
     * at next launch.
     */
    private fun installCrashCapture() {
        try {
            val crashFile = File(filesDir, "crash.txt")
            val prev = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
                try {
                    val sw = StringWriter()
                    throwable.printStackTrace(PrintWriter(sw))
                    crashFile.writeText("JAVA CRASH [${thread.name}]:\n$sw\n")
                } catch (_: Exception) {}
                prev?.uncaughtException(thread, throwable)
            }
        } catch (_: Exception) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installCrashCapture()
        // Load the FFI library at startup so its static initializer installs
        // the native signal handlers (SIGSEGV/SIGABRT/...) before any
        // inference runs.
        try {
            System.loadLibrary("flutter_blind_watermark")
        } catch (_: Throwable) {}
        showCrashReportIfAny()
        // Defensive: mark every app-owned directory with .nomedia so ROM
        // galleries never index transient files.
        try {
            for (d in listOf(
                cacheDir,
                getExternalCacheDir(),
                filesDir,
                getExternalFilesDir(null),
            )) {
                if (d == null) continue
                val nomedia = File(d, ".nomedia")
                if (!nomedia.exists()) nomedia.createNewFile()
            }
        } catch (_: Exception) {}
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        wamChannel = channel
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // Dart signals it has registered its handler.
                    "dartReady" -> {
                        dartReadyFlag = true
                        result.success(null)
                    }
                    "crashReportShown" -> {
                        deleteCrashReportFiles()
                        result.success(null)
                    }
                    // Directory with the bundled model files (extracted from
                    // assets on first use; the native WAM engine reads them).
                    "modelDir" -> {
                        val dir = File(filesDir, "models")
                        val ok1 = ensureModelFile("wam_embedder.onnx") != null
                        val ok2 = ensureModelFile("wam_extractor_int8.onnx") != null
                        if (ok1 && ok2) {
                            result.success(dir.absolutePath)
                        } else {
                            result.error("MODEL_ERROR", "models missing from app bundle", null)
                        }
                    }
                    // Pick an image and read the content URI bytes DIRECTLY
                    // into memory — no cache copy, no disk write — so ROM
                    // galleries can never index a transient file.
                    "pickImage" -> {
                        val res = result
                        pendingPickResult = res
                        runOnUiThread {
                            try {
                                startActivityForResult(
                                    Intent.createChooser(
                                        Intent(Intent.ACTION_GET_CONTENT).apply {
                                            type = "image/*"
                                            addCategory(Intent.CATEGORY_OPENABLE)
                                        },
                                        null
                                    ),
                                    PICK_IMAGE_REQ
                                )
                            } catch (e: Exception) {
                                pendingPickResult = null
                                try {
                                    res.error("PICK_ERROR", e.message ?: "unknown", null)
                                } catch (_: Exception) {}
                            }
                        }
                    }
                    else -> try {
                        result.notImplemented()
                    } catch (_: Exception) {}
                }
            } catch (e: Exception) {
                try {
                    result.error("WAM_ERROR", e.message ?: "unknown", null)
                } catch (_: Exception) {}
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_IMAGE_REQ) return
        val res = pendingPickResult ?: return
        pendingPickResult = null
        if (resultCode != RESULT_OK || data?.data == null) {
            // User cancelled — null means "no image picked".
            runOnUiThread { try { res.success(null) } catch (_: Exception) {} }
            return
        }
        val uri = data.data!!
        val name = queryDisplayName(uri) ?: "image"
        Thread {
            try {
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                runOnUiThread {
                    try {
                        if (bytes == null) {
                            res.error("PICK_ERROR", "cannot read image", null)
                        } else {
                            res.success(mapOf<String, Any>("bytes" to bytes, "name" to name))
                        }
                    } catch (_: Exception) {}
                }
            } catch (e: Exception) {
                runOnUiThread {
                    try { res.error("PICK_ERROR", e.message ?: "unknown", null) } catch (_: Exception) {}
                }
            }
        }.start()
    }

    private fun queryDisplayName(uri: android.net.Uri): String? {
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    /** Shows any crash report written by the previous run. The report files
     *  are only deleted once the user dismisses the dialog (crashReportShown)
     *  — so if the dialog is missed on one launch, the next launch shows it
     *  again instead of silently dropping the report. */
    private fun showCrashReportIfAny() {
        if (reportShownThisProcess) return
        reportShownThisProcess = true
        try {
            val sb = StringBuilder()
            sb.append("DEVICE: ")
                .append(Build.MANUFACTURER)
                .append(" ")
                .append(Build.MODEL)
                .append(" | Android ")
                .append(Build.VERSION.RELEASE)
                .append(" (SDK ")
                .append(Build.VERSION.SDK_INT)
                .append(")\n")
            for (f in listOf(File(filesDir, "crash.txt"), File(cacheDir, "crash.txt"))) {
                if (f.exists()) {
                    sb.append(f.readText()).append("\n")
                }
            }
            if (sb.isNotEmpty()) {
                val report = sb.toString()
                // Surface it through Flutter (Material 3 dialog) as soon as
                // the Dart side is ready; system AlertDialog as fallback.
                val handler = android.os.Handler(android.os.Looper.getMainLooper())
                val start = System.currentTimeMillis()
                val deliver = object : Runnable {
                    override fun run() {
                        val ch = wamChannel
                        if (ch != null && dartReadyFlag) {
                            try {
                                ch.invokeMethod("onCrashReport", report)
                                return
                            } catch (_: Exception) {}
                        }
                        if (System.currentTimeMillis() - start < 6000) {
                            handler.postDelayed(this, 200)
                            return
                        }
                        try {
                            val cb = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                            AlertDialog.Builder(this@MainActivity)
                                .setTitle("上次运行发生崩溃")
                                .setMessage(report)
                                .setPositiveButton("复制报告") { _, _ ->
                                    cb.setPrimaryClip(ClipData.newPlainText("crash", report))
                                }
                                .setNegativeButton("关闭", null)
                                .setOnDismissListener { deleteCrashReportFiles() }
                                .show()
                        } catch (_: Exception) {}
                    }
                }
                handler.post(deliver)
            }
        } catch (_: Exception) {}
    }

    private fun deleteCrashReportFiles() {
        try {
            File(filesDir, "crash.txt").delete()
            File(cacheDir, "crash.txt").delete()
            File(filesDir, "trail.txt").delete()
        } catch (_: Exception) {}
    }

    /**
     * Extracts a bundled model into filesDir once (the native WAM engine
     * reads the files via the ORT C API).
     *
     * Model cache invalidation: files left by an older install can be stale;
     * whenever the app version changes, wipe the cache and re-extract from
     * the bundled assets.
     */
    @Suppress("DEPRECATION")
    private fun ensureModelFile(name: String): File? {
        val dir = File(filesDir, "models")
        try {
            val ver = packageManager.getPackageInfo(packageName, 0).versionCode
            val stamp = File(dir, ".model_stamp")
            val ok = stamp.exists() && stamp.readText().trim() == ver.toString()
            if (!ok) {
                dir.listFiles()?.forEach { it.delete() }
                dir.mkdirs()
                stamp.writeText(ver.toString())
            }
        } catch (_: Exception) {}
        val f = File(dir, name)
        if (f.exists() && f.length() > 0) return f
        return try {
            assets.open("flutter_assets/assets/onnx/$name").use { input ->
                dir.mkdirs()
                FileOutputStream(f).use { out -> input.copyTo(out) }
            }
            f
        } catch (e: Exception) {
            null
        }
    }
}
