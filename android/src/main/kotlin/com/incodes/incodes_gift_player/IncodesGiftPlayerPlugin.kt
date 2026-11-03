package com.incodes.incodes_gift_player

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry
import org.libpag.PAGFile
import org.libpag.PAGFont
import org.libpag.PAGImage
import org.libpag.PAGLayer
import org.libpag.PAGPlayer
import org.libpag.PAGSurface
import org.libpag.PAGText
import org.libpag.PAGTextLayer
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Native half of the gift player: PAG playback through libpag.
 *
 * Every PAG gift is a [PagInstance]: a `PAGPlayer` that renders into a Flutter `SurfaceTexture` (so the gift is composited by Flutter
 * and is transparent over whatever is behind it). Dart drives the animation frame by frame (`pagRender` with a progress value), exactly
 * like the web package drives libpag, so loops, pause, seek and the events behave the same for every format.
 *
 * libpag needs the thread that created its GL context for every call, so all libpag work runs on one dedicated worker thread; results
 * are posted back to the main thread.
 */
class IncodesGiftPlayerPlugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var textures: TextureRegistry? = null
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private var thread: HandlerThread? = null
    private var worker: Handler? = null
    private val instances = ConcurrentHashMap<Int, PagInstance>()
    private val nextId = AtomicInteger(1)

    /** Failure that maps to a Dart `GiftErrorCode` (the error code string is the kebab-case id). */
    private class PagError(val code: String, message: String) : Exception(message)

    private class PagInstance(
        val id: Int,
        val entry: TextureRegistry.SurfaceTextureEntry,
        val surface: Surface,
        val pagSurface: PAGSurface,
        val player: PAGPlayer,
        val file: PAGFile,
    ) {
        val images = HashMap<Int, PAGImage>()

        fun release() {
            try {
                player.setSurface(null)
                player.release()
            } catch (_: Throwable) {
            }
            for (img in images.values) {
                try {
                    img.release()
                } catch (_: Throwable) {
                }
            }
            images.clear()
            try {
                pagSurface.release()
            } catch (_: Throwable) {
            }
            try {
                surface.release()
            } catch (_: Throwable) {
            }
            try {
                entry.release()
            } catch (_: Throwable) {
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "incodes_gift_player")
        channel.setMethodCallHandler(this)
        textures = binding.textureRegistry
        val t = HandlerThread("incodes-gift-player-pag")
        t.start()
        thread = t
        worker = Handler(t.looper)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        val all = instances.values.toList()
        instances.clear()
        val t = thread
        val w = worker
        if (w != null) {
            w.post {
                all.forEach { it.release() }
                t?.quitSafely()
            }
        } else {
            t?.quitSafely()
        }
        worker = null
        thread = null
        textures = null
    }

    // ---- dispatch -----------------------------------------------------------------------------------------------------------

    /** Runs [block] on the libpag worker thread and answers on the main thread. */
    private fun runOnWorker(result: Result, block: () -> Any?) {
        val w = worker
        if (w == null) {
            result.error("engine-load-failed", "The plugin is detached from the engine.", null)
            return
        }
        w.post {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: PagError) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: UnsatisfiedLinkError) {
                main.post { result.error("engine-load-failed", "libpag could not be loaded: ${e.message}", null) }
            } catch (e: Throwable) {
                main.post { result.error("decode-failed", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun instance(call: MethodCall): PagInstance {
        val id = (call.argument<Number>("id") ?: throw PagError("invalid-input", "Missing instance id.")).toInt()
        return instances[id] ?: throw PagError("invalid-input", "The PAG gift $id is already released.")
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "pagInit" -> runOnWorker(result) {
                // Touching any libpag class loads the native library; failures are reported as engine-load-failed.
                PAGFile.MaxSupportedTagLevel()
                null
            }
            "pagCreate" -> create(call, result)
            "pagRender" -> runOnWorker(result) {
                val inst = instance(call)
                inst.player.setProgress((call.argument<Number>("progress") ?: 0).toDouble())
                inst.player.flush()
                null
            }
            "pagResize" -> runOnWorker(result) {
                val inst = instance(call)
                val w = (call.argument<Number>("width") ?: 0).toInt()
                val h = (call.argument<Number>("height") ?: 0).toInt()
                if (w > 0 && h > 0) {
                    inst.entry.surfaceTexture().setDefaultBufferSize(w, h)
                    inst.pagSurface.updateSize()
                }
                null
            }
            "pagSetScaleMode" -> runOnWorker(result) {
                instance(call).player.setScaleMode((call.argument<Number>("mode") ?: 2).toInt())
                null
            }
            "pagGetTextData" -> runOnWorker(result) {
                val inst = instance(call)
                val index = (call.argument<Number>("index") ?: 0).toInt()
                textToMap(inst.file.getTextData(index) ?: throw PagError("invalid-input", "No editable text $index."))
            }
            "pagReplaceText" -> runOnWorker(result) {
                val inst = instance(call)
                val index = (call.argument<Number>("index") ?: 0).toInt()
                val doc = call.argument<Map<String, Any?>>("doc") ?: emptyMap()
                val text = inst.file.getTextData(index) ?: throw PagError("invalid-input", "No editable text $index.")
                applyTextMap(text, doc)
                inst.file.replaceText(index, text)
                null
            }
            "pagSetLayerText" -> runOnWorker(result) {
                val inst = instance(call)
                val name = call.argument<String>("name") ?: ""
                var changed = 0
                for (layer in inst.file.getLayersByName(name) ?: emptyArray()) {
                    if (layer.layerType() != PAGLayer.LayerTypeText) continue
                    val t = layer as? PAGTextLayer ?: continue
                    t.setText(call.argument<String>("text") ?: "")
                    call.argument<Number>("size")?.let { t.setFontSize(it.toFloat()) }
                    call.argument<Number>("color")?.let { t.setFillColor(it.toInt()) }
                    changed++
                }
                changed
            }
            "pagReplaceImage" -> runOnWorker(result) {
                val inst = instance(call)
                val index = (call.argument<Number>("index") ?: 0).toInt()
                val bytes = call.argument<ByteArray>("bytes") ?: throw PagError("invalid-input", "Missing image bytes.")
                val bmp: Bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    ?: throw PagError("decode-failed", "The replacement image could not be decoded.")
                val image = PAGImage.FromBitmap(bmp) ?: throw PagError("decode-failed", "libpag could not use the replacement image.")
                image.setScaleMode((call.argument<Number>("scaleMode") ?: 1).toInt())
                inst.file.replaceImage(index, image)
                inst.images.put(index, image)?.release()
                null
            }
            "pagSetLayerVisible" -> runOnWorker(result) {
                val inst = instance(call)
                val name = call.argument<String>("name")
                var layers: Array<PAGLayer> = if (name != null) inst.file.getLayersByName(name) ?: emptyArray() else emptyArray()
                if (layers.isEmpty()) {
                    val index = call.argument<Number>("index")
                    val type = call.argument<Number>("type")
                    if (index != null && type != null) {
                        layers = inst.file.getLayersByEditableIndex(index.toInt(), type.toInt()) ?: emptyArray()
                    }
                }
                val visible = call.argument<Boolean>("visible") ?: true
                for (l in layers) l.setVisible(visible)
                layers.size
            }
            "pagDispose" -> {
                val id = (call.argument<Number>("id") ?: 0).toInt()
                val inst = instances.remove(id)
                if (inst == null) {
                    result.success(null)
                } else {
                    runOnWorker(result) {
                        inst.release()
                        null
                    }
                }
            }
            "pagRegisterFont" -> runOnWorker(result) {
                val path = call.argument<String>("path") ?: throw PagError("invalid-input", "Missing font path.")
                if (!File(path).exists()) throw PagError("invalid-input", "The font file does not exist.")
                PAGFont.RegisterFont(path) ?: throw PagError("decode-failed", "libpag could not register this font.")
                null
            }
            else -> result.notImplemented()
        }
    }

    // ---- create -------------------------------------------------------------------------------------------------------------

    private fun create(call: MethodCall, result: Result) {
        val registry = textures
        if (registry == null) {
            result.error("engine-load-failed", "The plugin is detached from the engine.", null)
            return
        }
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null) {
            result.error("invalid-input", "Missing PAG bytes.", null)
            return
        }
        val reqW = (call.argument<Number>("width") ?: 0).toInt()
        val reqH = (call.argument<Number>("height") ?: 0).toInt()
        // Texture entries are created on the main thread; libpag work follows on the worker.
        val entry = registry.createSurfaceTexture()
        val guarded = object : Result {
            override fun success(value: Any?) = result.success(value)
            override fun error(code: String, message: String?, details: Any?) {
                entry.release()
                result.error(code, message, details)
            }

            override fun notImplemented() = result.notImplemented()
        }
        runOnWorker(guarded) {
            val file = PAGFile.Load(bytes)
                ?: throw PagError("parse-failed", "The PAG engine could not parse this file (corrupt, or newer than the engine supports).")
            val w = if (reqW > 0) reqW else file.width()
            val h = if (reqH > 0) reqH else file.height()
            entry.surfaceTexture().setDefaultBufferSize(w, h)
            val surface = Surface(entry.surfaceTexture())
            val pagSurface = PAGSurface.FromSurface(surface)
            if (pagSurface == null) {
                surface.release()
                throw PagError("unsupported-format", "Could not create a PAG surface (GL unavailable or out of memory).")
            }
            val player = PAGPlayer()
            player.setSurface(pagSurface)
            player.setComposition(file)
            player.setScaleMode(2) // letterbox (aspectFit); Dart sets the real mode right after
            val id = nextId.getAndIncrement()
            instances[id] = PagInstance(id, entry, surface, pagSurface, player, file)

            val textIdx = file.getEditableIndices(PAGLayer.LayerTypeText) ?: IntArray(0)
            val imageIdx = file.getEditableIndices(PAGLayer.LayerTypeImage) ?: IntArray(0)
            fun names(indices: IntArray, type: Int): List<String> = indices.map {
                file.getLayersByEditableIndex(it, type)?.firstOrNull()?.layerName() ?: ""
            }
            mapOf(
                "id" to id,
                "textureId" to entry.id(),
                "width" to file.width(),
                "height" to file.height(),
                "duration" to file.duration(), // microseconds
                "frameRate" to file.frameRate().toDouble(),
                "textIndices" to textIdx.toList(),
                "imageIndices" to imageIdx.toList(),
                "textNames" to names(textIdx, PAGLayer.LayerTypeText),
                "imageNames" to names(imageIdx, PAGLayer.LayerTypeImage),
            )
        }
    }

    // ---- text documents -----------------------------------------------------------------------------------------------------

    private fun opaque(color: Int): Int = color or (0xFF shl 24)

    private fun textToMap(t: PAGText): Map<String, Any?> = mapOf(
        "text" to t.text,
        "fontSize" to t.fontSize.toDouble(),
        "fontFamily" to t.fontFamily,
        "fontStyle" to t.fontStyle,
        "fillColor" to opaque(t.fillColor),
        "strokeColor" to opaque(t.strokeColor),
        "strokeWidth" to t.strokeWidth.toDouble(),
        "applyFill" to t.applyFill,
        "applyStroke" to t.applyStroke,
        "justification" to t.justification,
        "fauxBold" to t.fauxBold,
    )

    private fun applyTextMap(t: PAGText, m: Map<String, Any?>) {
        (m["text"] as? String)?.let { t.text = it }
        (m["fontSize"] as? Number)?.let { t.fontSize = it.toFloat() }
        (m["fontFamily"] as? String)?.let { t.fontFamily = it }
        (m["fontStyle"] as? String)?.let { t.fontStyle = it }
        (m["fillColor"] as? Number)?.let { t.fillColor = it.toInt() }
        (m["strokeColor"] as? Number)?.let { t.strokeColor = it.toInt() }
        (m["strokeWidth"] as? Number)?.let { t.strokeWidth = it.toFloat() }
        (m["applyFill"] as? Boolean)?.let { t.applyFill = it }
        (m["applyStroke"] as? Boolean)?.let { t.applyStroke = it }
        (m["justification"] as? Number)?.let { t.justification = it.toInt() }
        (m["fauxBold"] as? Boolean)?.let { t.fauxBold = it }
    }
}
