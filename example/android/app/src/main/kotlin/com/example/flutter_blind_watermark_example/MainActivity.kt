package com.example.flutter_blind_watermark_example

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.ByteArrayOutputStream
import java.lang.reflect.Array

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "wam"
        private const val IMG_SIZE = 256
        // ImageNet stats matching the WAM transforms
        private val MEAN = floatArrayOf(0.485f, 0.456f, 0.406f)
        private val STD = floatArrayOf(0.229f, 0.224f, 0.225f)
    }

    private var ortEnv: OrtEnvironment? = null
    private var embedSession: OrtSession? = null
    private var extractSession: OrtSession? = null

    // ONNX sessions are NOT thread-safe: serialize all inference on a single
    // worker thread (embed + extract can otherwise run concurrently from the
    // two pages and crash).
    private val inferenceExecutor =
        java.util.concurrent.Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Defensive: mark the app cache dir so ROM galleries never index any
        // transient file that ends up there.
        try {
            val nomedia = java.io.File(cacheDir, ".nomedia")
            if (!nomedia.exists()) nomedia.createNewFile()
        } catch (_: Exception) {}
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                // Heavy ONNX inference must never run on the platform (UI)
                // thread — it would block rendering and risk an ANR.
                inferenceExecutor.execute {
                    try {
                        when (call.method) {
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
            }
    }

    private fun getEnv(): OrtEnvironment {
        ortEnv?.let { return it }
        val env = OrtEnvironment.getEnvironment()
        ortEnv = env
        return env
    }

    /** Model files are bundled in Flutter assets. Flutter packages assets
     *  under assets/flutter_assets/<declared path>, so the native lookup must
     *  use the full path. */
    private fun modelBytes(name: String): ByteArray? {
        return try {
            assets.open("flutter_assets/assets/onnx/$name").readBytes()
        } catch (e: Exception) {
            null
        }
    }

    /** Lightweight existence check — must NOT read the 95MB model into
     *  memory every time. */
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
        val bytes = modelBytes("wam_embedder.onnx")
            ?: throw IllegalArgumentException("embedder model missing from app bundle")
        embedSession = env.createSession(bytes, OrtSession.SessionOptions())
        return embedSession!!
    }

    private fun getExtractSession(): OrtSession {
        extractSession?.let { return it }
        val env = getEnv()
        val bytes = modelBytes("wam_extractor_int8.onnx")
            ?: throw IllegalArgumentException("extractor model missing from app bundle")
        extractSession = env.createSession(bytes, OrtSession.SessionOptions())
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
        inferenceExecutor.shutdown()
        super.onDestroy()
    }
}

