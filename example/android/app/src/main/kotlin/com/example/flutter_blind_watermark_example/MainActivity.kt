package com.example.flutter_blind_watermark_example

import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.PrintWriter
import java.io.StringWriter
import java.lang.reflect.Array

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "wam"
        private const val IMG_SIZE = 256
        private const val PICK_IMAGE_REQ = 0x4147 // "AG"
        // ImageNet stats matching the WAM transforms
        private val MEAN = floatArrayOf(0.485f, 0.456f, 0.406f)
        private val STD = floatArrayOf(0.229f, 0.224f, 0.225f)
    }

    private var ortEnv: OrtEnvironment? = null
    private var embedSession: OrtSession? = null
    private var extractSession: OrtSession? = null

    private var pendingPickResult: MethodChannel.Result? = null

    /**
     * Captures uncaught Java/Kotlin exceptions (e.g. OOM, UnsatisfiedLinkError
     * on the inference executor) into filesDir/crash.txt, then re-raises so
     * the crash behavior is unchanged. The native side (blind_watermark_ffi)
     * writes NATIVE CRASH markers into the same file via its own signal
     * handlers; showCrashReportIfAny surfaces the report at next launch.
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

    /** Shows any crash report written by the previous run, then deletes it. */
    private fun showCrashReportIfAny() {
        try {
            val sb = StringBuilder()
            for (f in listOf(File(filesDir, "crash.txt"), File(cacheDir, "crash.txt"))) {
                if (f.exists()) {
                    sb.append(f.readText()).append("\n")
                    f.delete()
                }
            }
            if (sb.isNotEmpty()) {
                val report = sb.toString()
                runOnUiThread {
                    try {
                        val cb = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                        AlertDialog.Builder(this)
                            .setTitle("上次运行发生崩溃")
                            .setMessage(report)
                            .setPositiveButton("复制报告") { _, _ ->
                                cb.setPrimaryClip(ClipData.newPlainText("crash", report))
                            }
                            .setNegativeButton("关闭", null)
                            .show()
                    } catch (_: Exception) {}
                }
            }
        } catch (_: Exception) {}
    }

    // ONNX sessions are NOT thread-safe: serialize all inference on a single
    // worker thread. Lazily (re)created: the Activity can be destroyed and
    // recreated (rotation, low memory), which would otherwise leave us with a
    // shut-down executor that throws on every call.
    private var inferenceExecutor: java.util.concurrent.ExecutorService? = null

    private fun executor(): java.util.concurrent.ExecutorService {
        val e = inferenceExecutor
        if (e != null && !e.isShutdown) return e
        val fresh = java.util.concurrent.Executors.newSingleThreadExecutor()
        inferenceExecutor = fresh
        return fresh
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installCrashCapture()
        // Load the FFI library at startup so its static initializer installs
        // the native signal handlers (SIGSEGV/SIGABRT/...) BEFORE any
        // inference runs — the WAM/ONNX path never loads it via Dart FFI.
        try {
            System.loadLibrary("flutter_blind_watermark")
        } catch (_: Throwable) {}
        showCrashReportIfAny()
        // Defensive: mark every app-owned directory with .nomedia so ROM
        // galleries never index transient files (file_picker cache copies,
        // logo temp files, model files). Some ROMs scan the external cache
        // too, so cover both internal and external dirs.
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                // Heavy ONNX inference must never run on the platform (UI)
                // thread — it would block rendering and risk an ANR.
                try {
                    executor().execute {
                        try {
                            when (call.method) {
                                // Pick an image and read the content URI bytes
                                // DIRECTLY into memory — no cache copy, no disk
                                // write — so ROM galleries can never index a
                                // transient file (file_picker writes one even
                                // with withData:true; some ROMs index it).
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
                                "embed" -> {
                                    val img = call.argument<ByteArray>("img")!!
                                    val bits = call.argument<List<Double>>("bits")!!
                                    val out = embed(img, bits)
                                    runOnUiThread {
                                        try { result.success(out) } catch (_: Exception) {}
                                    }
                                }
                                "extract" -> {
                                    val img = call.argument<ByteArray>("img")!!
                                    val out = extract(img)
                                    runOnUiThread {
                                        try { result.success(out) } catch (_: Exception) {}
                                    }
                                }
                                "modelReady" -> {
                                    val ready = modelReady()
                                    runOnUiThread {
                                        try { result.success(ready) } catch (_: Exception) {}
                                    }
                                }
                                "reloadModels" -> {
                                    reloadModels()
                                    val ready = modelReady()
                                    runOnUiThread {
                                        try { result.success(ready) } catch (_: Exception) {}
                                    }
                                }
                                else -> runOnUiThread {
                                    try { result.notImplemented() } catch (_: Exception) {}
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                try {
                                    result.error("WAM_ERROR", e.message ?: "unknown", null)
                                } catch (_: Exception) {}
                            }
                        }
                    }
                } catch (e: Exception) {
                    // Never crash the app on channel setup issues.
                    runOnUiThread {
                        try {
                            result.error("WAM_ERROR", e.message ?: "unknown", null)
                        } catch (_: Exception) {}
                    }
                }
            }
    }

    private fun getEnv(): OrtEnvironment {
        ortEnv?.let { return it }
        val env = OrtEnvironment.getEnvironment()
        ortEnv = env
        return env
    }

    /**
     * Extracts a bundled model into filesDir once, then loads the session
     * from the file path — avoids holding a 95MB byte[] plus the session
     * copy in memory at the same time.
     *
     * Model cache invalidation: files left by an older install (or by the
     * removed download flow) can be stale — e.g. an external-data ONNX whose
     * .data file is absent makes session creation fail with ORT "External
     * data path does not exist". Whenever the app version changes, wipe the
     * cache and re-extract from the bundled assets.
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

    /** Lightweight existence check — never reads the model into memory. */
    private fun modelReady(): Boolean {
        return try {
            assets.open("flutter_assets/assets/onnx/wam_embedder.onnx").close()
            assets.open("flutter_assets/assets/onnx/wam_extractor_int8.onnx").close()
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun reloadModels() {
        embedSession?.close()
        extractSession?.close()
        embedSession = null
        extractSession = null
    }

    private fun getEmbedSession(): OrtSession {
        embedSession?.let { return it }
        val env = getEnv()
        val model = ensureModelFile("wam_embedder.onnx")
            ?: throw IllegalArgumentException("embedder model missing from app bundle")
        embedSession = env.createSession(model.path, OrtSession.SessionOptions())
        return embedSession!!
    }

    private fun getExtractSession(): OrtSession {
        extractSession?.let { return it }
        val env = getEnv()
        val model = ensureModelFile("wam_extractor_int8.onnx")
            ?: throw IllegalArgumentException("extractor model missing from app bundle")
        extractSession = env.createSession(model.path, OrtSession.SessionOptions())
        return extractSession!!
    }

    private fun decodeBitmap(bytes: ByteArray, size: Int): Bitmap {
        val src = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalArgumentException("cannot decode image")
        return Bitmap.createScaledBitmap(src, size, size, true)
    }

    /** RGB uint8 [H,W,3] -> normalized CHW float32 [1,3,H,W] (flattened) */
    private fun toTensor(bmp: Bitmap): FloatArray {
        val out = FloatArray(3 * IMG_SIZE * IMG_SIZE)
        val px = IntArray(IMG_SIZE * IMG_SIZE)
        bmp.getPixels(px, 0, IMG_SIZE, 0, 0, IMG_SIZE, IMG_SIZE)
        val hw = IMG_SIZE * IMG_SIZE
        for (i in 0 until hw) {
            val p = px[i]
            val r = ((p shr 16) and 0xFF) / 255f
            val g = ((p shr 8) and 0xFF) / 255f
            val b = (p and 0xFF) / 255f
            out[i] = (r - MEAN[0]) / STD[0]
            out[i + hw] = (g - MEAN[1]) / STD[1]
            out[i + 2 * hw] = (b - MEAN[2]) / STD[2]
        }
        return out
    }

    /** normalized CHW float32 (flattened, 3*H*W) -> RGB uint8 Bitmap */
    private fun fromTensor(t: FloatArray): Bitmap {
        val hw = IMG_SIZE * IMG_SIZE
        val px = IntArray(hw)
        for (i in 0 until hw) {
            fun unnorm(v: Float, ch: Int): Int {
                val x = (v * STD[ch] + MEAN[ch]) * 255f
                return x.coerceIn(0f, 255f).toInt() and 0xFF
            }
            val r = unnorm(t[i], 0)
            val g = unnorm(t[i + hw], 1)
            val b = unnorm(t[i + 2 * hw], 2)
            px[i] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
        }
        return Bitmap.createBitmap(px, IMG_SIZE, IMG_SIZE, Bitmap.Config.ARGB_8888)
    }

    /**
     * Recursively flatten the nested array structure ONNX Runtime Java returns
     * for float tensors (varies by opset/version): FloatArray / Array<FloatArray>
     * / deeper nesting. Order is row-major (C order).
     */
    private fun flattenFloats(value: Any): FloatArray {
        val out = ArrayList<Float>()
        fun walk(v: Any) {
            when (v) {
                is FloatArray -> for (f in v) out.add(f)
                is DoubleArray -> for (d in v) out.add(d.toFloat())
                is Float -> out.add(v)
                is Double -> out.add(v.toFloat())
                is Int -> out.add(v.toFloat())
                else -> {
                    if (v.javaClass.isArray) {
                        val len = Array.getLength(v)
                        for (i in 0 until len) walk(Array.get(v, i))
                    } else {
                        throw IllegalArgumentException("unexpected tensor element: ${v.javaClass}")
                    }
                }
            }
        }
        walk(value)
        return out.toFloatArray()
    }

    private fun embed(imgBytes: ByteArray, bits: List<Double>): ByteArray {
        val bmp = decodeBitmap(imgBytes, IMG_SIZE)
        val tensor = toTensor(bmp)
        val env = getEnv()
        val sess = getEmbedSession()
        val msg = FloatArray(32) { if (bits.getOrElse(it) { 0.0 } > 0.5) 1f else 0f }
        var imgTensor: OnnxTensor? = null
        var msgTensor: OnnxTensor? = null
        var out: OrtSession.Result? = null
        try {
            imgTensor = OnnxTensor.createTensor(env, java.nio.FloatBuffer.wrap(tensor),
                longArrayOf(1, 3, IMG_SIZE.toLong(), IMG_SIZE.toLong()))
            msgTensor = OnnxTensor.createTensor(env, java.nio.FloatBuffer.wrap(msg), longArrayOf(1, 32))
            out = sess.run(mapOf("img" to imgTensor, "msg" to msgTensor))
            val flat = flattenFloats(out.get(0).value)
            // flat is [1,3,256,256] in C order -> channels are contiguous blocks
            val hw = IMG_SIZE * IMG_SIZE
            val wm = FloatArray(3 * hw)
            System.arraycopy(flat, 0, wm, 0, hw)
            System.arraycopy(flat, hw, wm, hw, hw)
            System.arraycopy(flat, 2 * hw, wm, 2 * hw, hw)
            val outBmp = fromTensor(wm)
            val bos = ByteArrayOutputStream()
            outBmp.compress(Bitmap.CompressFormat.PNG, 100, bos)
            return bos.toByteArray()
        } finally {
            imgTensor?.close()
            msgTensor?.close()
            out?.close()
        }
    }

    private fun extract(imgBytes: ByteArray): List<Int> {
        val bmp = decodeBitmap(imgBytes, IMG_SIZE)
        val tensor = toTensor(bmp)
        val env = getEnv()
        val sess = getExtractSession()
        var imgTensor: OnnxTensor? = null
        var out: OrtSession.Result? = null
        try {
            imgTensor = OnnxTensor.createTensor(env, java.nio.FloatBuffer.wrap(tensor),
                longArrayOf(1, 3, IMG_SIZE.toLong(), IMG_SIZE.toLong()))
            out = sess.run(mapOf("img" to imgTensor))
            val flat = flattenFloats(out.get(0).value)
            // flat is [1,33,256,256] C order: channel k occupies [k*hw, (k+1)*hw)
            val hw = IMG_SIZE * IMG_SIZE
            val maskRaw = FloatArray(hw)
            System.arraycopy(flat, 0, maskRaw, 0, hw)
            val maskSel = BooleanArray(hw)
            var cnt = 0
            for (i in 0 until hw) {
                maskSel[i] = 1f / (1f + Math.exp(-maskRaw[i].toDouble())) > 0.5
                if (maskSel[i]) cnt++
            }
            val result = ArrayList<Int>(32)
            for (k in 1..32) {
                val off = k * hw
                var sum = 0.0
                var n = 0
                for (i in 0 until hw) {
                    if (maskSel[i]) {
                        sum += flat[off + i]
                        n++
                    }
                }
                result.add(if (n > 0 && sum / n > 0.0) 1 else 0)
            }
            return result
        } finally {
            imgTensor?.close()
            out?.close()
        }
    }

    override fun onDestroy() {
        embedSession?.close()
        extractSession?.close()
        ortEnv?.close()
        // Shut down but keep the reference: the lazy executor() getter
        // recreates it if the Activity is rebuilt.
        inferenceExecutor?.shutdown()
        super.onDestroy()
    }
}

