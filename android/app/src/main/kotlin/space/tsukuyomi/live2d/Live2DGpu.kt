package space.tsukuyomi.live2d

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import androidx.annotation.Keep
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** SurfaceProducer owns the output; EGL/Cubism own the drawing on one worker. */
@Keep
class Live2DGpu(engine: FlutterEngine) : MethodChannel.MethodCallHandler {
    companion object {
        // Cubism shares shaders globally. Every scene and engine uses the same
        // context thread, including overlapping Activity teardown/recreation.
        private val thread = HandlerThread("Tsukuyomi-Cubism-GPU").apply { start() }
        private val worker = Handler(thread.looper)
    }
    private val main = Handler(Looper.getMainLooper())
    private val registry = engine.renderer
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "space.tsukuyomi/live2d_gpu")
    private val scenes = mutableMapOf<Long, Scene>()
    private var closed = false
    private class Scene(val producer: TextureRegistry.SurfaceProducer) {
        // pointer/output are accessed only on worker; available on main.
        var pointer = 0L
        var output: Surface? = null
        @Volatile var available = true
    }
    init { channel.setMethodCallHandler(this) }
    private fun task(result: MethodChannel.Result, work: () -> Any?) {
        worker.post {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("gpu", e.message ?: "Native GPU unavailable", null) }
            }
        }
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (closed) { result.error("disposed", "Renderer closed", null); return }
        if (call.method == "create") {
            val producer = registry.createSurfaceProducer()
            producer.setSize(1, 1)
            val scene = Scene(producer)
            scenes[producer.id()] = scene
            producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    scene.available = true
                    channel.invokeMethod("surfaceAvailable", mapOf("id" to producer.id()))
                }
                override fun onSurfaceCleanup() {
                    scene.available = false
                    worker.post {
                        if (scene.pointer != 0L) {
                            try { nativeSurface(scene.pointer, null) } catch (_: Throwable) { }
                        }
                        scene.output = null
                    }
                }
            })
            task(result) {
                try {
                    val started = System.nanoTime()
                    System.loadLibrary("tsukuyomi_live2d")
                    scene.pointer = nativeCreate(call.argument<ByteArray>("moc")!!,
                        call.argument<ByteArray>("physics") ?: byteArrayOf())
                    val info = nativeInfo(scene.pointer)
                    val initialized = System.nanoTime()
                    var uploadNanos = 0L
                    val limit = min(call.argument<Int>("maxTextureSize") ?: 3072, info[5].toInt())
                    require(limit > 0) { "Invalid texture limit" }
                    var bytes = 0L
                    val atlases = call.argument<List<ByteArray>>("textures")!!
                    atlases.forEachIndexed { index, data ->
                        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
                        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Invalid atlas" }
                        var sample = 1
                        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= limit) sample *= 2
                        var bitmap = BitmapFactory.decodeByteArray(data, 0, data.size,
                            BitmapFactory.Options().apply {
                                inSampleSize = sample
                                inPreferredConfig = Bitmap.Config.ARGB_8888
                                inPremultiplied = true
                                inScaled = false
                            }) ?: error("Cannot decode atlas")
                        try {
                            val ratio = min(1.0, limit.toDouble() / max(bitmap.width, bitmap.height))
                            var targetWidth = max(1, (bitmap.width * ratio).roundToInt())
                            var targetHeight = max(1, (bitmap.height * ratio).roundToInt())
                            // Cubism uses repeat + mipmap filtering. GLES2 without
                            // full NPOT support requires power-of-two atlases.
                            if (info[6] == 0.0) {
                                targetWidth = Integer.highestOneBit(targetWidth)
                                targetHeight = Integer.highestOneBit(targetHeight)
                            }
                            if (targetWidth != bitmap.width || targetHeight != bitmap.height) {
                                val scaled = Bitmap.createScaledBitmap(bitmap,
                                    targetWidth, targetHeight, true)
                                if (scaled !== bitmap) bitmap.recycle()
                                bitmap = scaled
                            }
                            val uploadStart = System.nanoTime()
                            nativeTexture(scene.pointer, index, bitmap)
                            uploadNanos += System.nanoTime() - uploadStart
                            var mipWidth = bitmap.width
                            var mipHeight = bitmap.height
                            while (true) {
                                bytes += mipWidth.toLong() * mipHeight * 4
                                if (mipWidth == 1 && mipHeight == 1) break
                                mipWidth = max(1, mipWidth / 2)
                                mipHeight = max(1, mipHeight / 2)
                            }
                        } finally { bitmap.recycle() }
                    }
                    mapOf("textureId" to producer.id(), "bounds" to info.take(4),
                        "meshCount" to info[4].toInt(), "maxSize" to min(4096, info[5].toInt()),
                        "atlasBytes" to bytes,
                        "loadMetrics" to mapOf(
                            "native_init_ms" to (initialized - started) / 1e6,
                            "atlas_decode_ms" to (System.nanoTime() - initialized - uploadNanos) / 1e6,
                            "atlas_upload_ms" to uploadNanos / 1e6,
                            "shader_source_loads" to info[7].toInt()))
                } catch (e: Throwable) {
                    if (scene.pointer != 0L) nativeDestroy(scene.pointer)
                    scene.pointer = 0
                    main.post { scenes.remove(producer.id()); producer.setCallback(null); producer.release() }
                    throw e
                }
            }
            return
        }
        val scene = scenes[call.argument<Number>("id")?.toLong()]
        if (scene == null) { result.error("disposed", "Unknown renderer", null); return }
        when (call.method) {
            "frame" -> {
                if (!scene.available) { result.success(mapOf("paused" to true)); return }
                val width = call.argument<Int>("width") ?: 1
                val height = call.argument<Int>("height") ?: 1
                if (width !in 1..4096 || height !in 1..4096 || width.toLong() * height > 8000000) {
                    result.error("size", "Invalid output size", null); return
                }
                if (scene.producer.width != width || scene.producer.height != height) {
                    scene.producer.setSize(width, height)
                }
                // Never retain an obsolete Surface across resize/background.
                val surface = scene.producer.surface
                task(result) {
                    check(scene.pointer != 0L)
                    if (!scene.available) return@task mapOf("paused" to true)
                    val metrics = try {
                        if (surface !== scene.output) {
                            nativeSurface(scene.pointer, surface)
                            scene.output = surface
                        }
                        nativeFrame(scene.pointer,
                            call.argument<List<String>>("ids")!!.toTypedArray(),
                            call.argument<DoubleArray>("values")!!,
                            call.argument<IntArray>("blends")!!,
                            call.argument<Number>("delta")!!.toDouble())
                    } catch (e: Throwable) {
                        if (!scene.available) return@task mapOf("paused" to true)
                        throw e
                    }
                    mapOf("updateMicros" to metrics[0], "submitMicros" to metrics[1],
                        "presentMicros" to metrics[2], "width" to metrics[3].toInt(), "height" to metrics[4].toInt())
                }
            }
            "recreateSurfaceForTesting" -> {
                scene.producer.getForcedNewSurface()
                result.success(null)
            }
            "snapshot" -> task(result) { nativeSnapshot(scene.pointer) }
            "dispose" -> {
                scenes.remove(scene.producer.id())
                scene.producer.setCallback(null)
                worker.post {
                    if (scene.pointer != 0L) nativeDestroy(scene.pointer)
                    scene.pointer = 0; scene.output = null
                    main.post { scene.producer.release(); result.success(null) }
                }
            }
            else -> result.notImplemented()
        }
    }
    fun dispose() {
        closed = true
        channel.setMethodCallHandler(null)
        scenes.values.toList().forEach { scene ->
            scene.producer.setCallback(null)
            worker.post {
                if (scene.pointer != 0L) nativeDestroy(scene.pointer)
                scene.pointer = 0; scene.output = null
                main.post { scene.producer.release() }
            }
        }
        scenes.clear()
    }
    private external fun nativeCreate(moc: ByteArray, physics: ByteArray): Long
    private external fun nativeInfo(handle: Long): DoubleArray
    private external fun nativeTexture(handle: Long, index: Int, bitmap: Bitmap)
    private external fun nativeSurface(handle: Long, surface: Surface?)
    private external fun nativeFrame(handle: Long, ids: Array<String>, values: DoubleArray,
        blends: IntArray, delta: Double): DoubleArray
    private external fun nativeSnapshot(handle: Long): ByteArray
    private external fun nativeDestroy(handle: Long)
}
