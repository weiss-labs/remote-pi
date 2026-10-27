package work.jacobmoura.remotepi

import android.app.Activity
import android.app.Dialog
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

/** Native, app-private viewer. No desktop paths, URLs, or external app grants. */
class ArtifactViewer(private val activity: Activity) {
    private val directory = File(activity.cacheDir, "paired-artifacts")
    private val handler = Handler(Looper.getMainLooper())
    private var dialog: Dialog? = null
    private var renderer: PdfRenderer? = null
    private var bitmap: Bitmap? = null
    private var completion: MethodChannel.Result? = null
    private val expiry = Runnable { dismiss() }
    init { directory.deleteRecursively() }

    fun open(bytes: ByteArray?, extension: String?, result: MethodChannel.Result) {
        if (completion != null || bytes == null || bytes.isEmpty() || bytes.size > 20 * 1024 * 1024 ||
            extension !in setOf("pdf", "png", "jpg", "gif", "webp") || !valid(bytes, extension)) {
            result.error("invalid_preview", "Invalid preview data", null); return
        }
        try {
            directory.mkdirs()
            val file = File(directory, UUID.randomUUID().toString() + "." + extension)
            file.writeBytes(bytes)
            val viewer = Dialog(activity, android.R.style.Theme_Material_NoActionBar)
            viewer.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            val layout = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
            val controls = LinearLayout(activity)
            val label = TextView(activity)
            val image = ImageView(activity).apply {
                scaleType = ImageView.ScaleType.FIT_CENTER
                contentDescription = "File preview, pinch to zoom and drag to pan"
            }
            var scale = 1f
            var x = 0f
            var y = 0f
            val detector = ScaleGestureDetector(activity, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
                override fun onScale(d: ScaleGestureDetector): Boolean {
                    scale = (scale * d.scaleFactor).coerceIn(1f, 8f)
                    image.scaleX = scale; image.scaleY = scale
                    return true
                }
            })
            image.setOnTouchListener { _, event ->
                detector.onTouchEvent(event)
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> { x = event.rawX; y = event.rawY }
                    MotionEvent.ACTION_MOVE -> {
                        if (!detector.isInProgress && scale > 1) {
                            image.translationX += event.rawX - x
                            image.translationY += event.rawY - y
                        }
                        x = event.rawX; y = event.rawY
                    }
                    MotionEvent.ACTION_UP -> image.performClick()
                }
                true
            }
            fun showPage(index: Int) {
                val pdf = renderer ?: return
                pdf.openPage(index).use { page ->
                    // Bounded raster allocation even for adversarial PDF dimensions.
                    val ratio = 1600.0 / maxOf(page.width, page.height, 1)
                    val next = Bitmap.createBitmap(maxOf(1, (page.width * ratio).toInt()), maxOf(1, (page.height * ratio).toInt()), Bitmap.Config.ARGB_8888)
                    next.eraseColor(android.graphics.Color.WHITE)
                    page.render(next, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    image.setImageBitmap(next)
                    bitmap?.recycle(); bitmap = next
                }
                scale = 1f; image.scaleX = 1f; image.scaleY = 1f
                image.translationX = 0f; image.translationY = 0f
                label.text = "${index + 1} / ${pdf.pageCount}"
            }
            if (extension == "pdf") {
                renderer = PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY))
                var page = 0
                controls.addView(Button(activity).apply { text = "Previous"; setOnClickListener { if (page > 0) showPage(--page) } })
                controls.addView(Button(activity).apply { text = "Next"; setOnClickListener { if (page + 1 < renderer!!.pageCount) showPage(++page) } })
                showPage(0)
            } else {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(file.path, bounds)
                val options = BitmapFactory.Options().apply { inSampleSize = 1 }
                while (maxOf(bounds.outWidth, bounds.outHeight) / options.inSampleSize > 4096) options.inSampleSize *= 2
                bitmap = BitmapFactory.decodeFile(file.path, options) ?: throw IllegalArgumentException()
                image.setImageBitmap(bitmap)
            }
            controls.addView(Button(activity).apply { text = "Close"; setOnClickListener { dismiss() } })
            layout.addView(controls)
            layout.addView(label)
            layout.addView(image, LinearLayout.LayoutParams(-1, 0, 1f))
            viewer.setContentView(layout)
            completion = result
            dialog = viewer
            viewer.setOnDismissListener { cleanup() }
            viewer.show()
            viewer.window?.setLayout(-1, -1)
            handler.postDelayed(expiry, 300_000)
        } catch (_: Exception) {
            completion = null
            cleanup()
            result.error("preview_failed", "Unable to open private preview", null)
        }
    }
    private fun valid(bytes: ByteArray, ext: String?): Boolean {
        fun starts(vararg prefix: Int) = bytes.size >= prefix.size && prefix.indices.all { (bytes[it].toInt() and 255) == prefix[it] }
        fun text(start: Int, end: Int) = if (bytes.size >= end) String(bytes, start, end - start, Charsets.US_ASCII) else ""
        return when (ext) {
            "pdf" -> text(0, 5) == "%PDF-"
            "png" -> starts(137,80,78,71,13,10,26,10)
            "jpg" -> starts(255,216,255)
            "gif" -> text(0, 6) in setOf("GIF87a", "GIF89a")
            "webp" -> text(0, 4) == "RIFF" && text(8, 12) == "WEBP"
            else -> false
        }
    }
    fun dismiss() { dialog?.dismiss(); cleanup() }
    private fun cleanup() {
        handler.removeCallbacks(expiry)
        dialog = null
        renderer?.close(); renderer = null
        bitmap?.recycle(); bitmap = null
        directory.deleteRecursively()
        val result = completion; completion = null
        result?.success(null)
    }
}
