package app.tauri.nativeaudio

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** 只保留当前歌曲的缩略图，切歌立即取消旧请求，不在主线程读图。 */
internal class MediaArtwork(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var task: Future<*>? = null
    @Volatile private var generation = 0
    @Volatile private var connection: HttpURLConnection? = null
    private var source = ""
    var bitmap: Bitmap? = null
        private set

    fun load(value: String, ready: () -> Unit) {
        if (value == source) return
        source = value
        val token = ++generation
        task?.cancel(true)
        connection?.disconnect()
        bitmap = null
        if (value.isBlank()) return
        task = executor.submit {
            var temporary: File? = null
            var request: HttpURLConnection? = null
            try {
                val uri = Uri.parse(value)
                val applicationAsset = uri.scheme == "asset" && uri.host == "localhost" ||
                    uri.scheme in listOf("http", "https") && uri.host == "asset.localhost"
                val open: () -> InputStream? = if (applicationAsset) {
                    val path = Uri.decode(uri.encodedPath?.removePrefix("/").orEmpty())
                    ({ File(path).inputStream() })
                } else when (uri.scheme) {
                    "http", "https" -> {
                        val http = URL(value).openConnection() as HttpURLConnection
                        request = http
                        connection = http
                        http.connectTimeout = 10000
                        http.readTimeout = 10000
                        if (http.responseCode !in 200..299) throw IllegalArgumentException("封面请求失败")
                        val file = File.createTempFile("media-artwork-", ".tmp", context.cacheDir)
                        temporary = file
                        http.inputStream.use { input ->
                            file.outputStream().use { output ->
                                val buffer = ByteArray(8192)
                                var size = 0
                                while (true) {
                                    if (token != generation || Thread.currentThread().isInterrupted) return@submit
                                    val read = input.read(buffer)
                                    if (read < 0) break
                                    size += read
                                    if (size > 8 * 1024 * 1024) throw IllegalArgumentException("封面过大")
                                    output.write(buffer, 0, read)
                                }
                            }
                        }
                        ({ file.inputStream() })
                    }
                    "file", "content" -> ({ context.contentResolver.openInputStream(uri) })
                    null -> ({ File(value).inputStream() })
                    else -> throw IllegalArgumentException("不支持的封面路径")
                }
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                open()?.use { BitmapFactory.decodeStream(it, null, bounds) }
                var sample = 1
                while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 1024) sample *= 2
                val options = BitmapFactory.Options().apply { inSampleSize = sample }
                val decoded = open()?.use { BitmapFactory.decodeStream(it, null, options) }
                handler.post {
                    if (token == generation) {
                        bitmap = decoded
                        ready()
                    }
                }
            } catch (error: Exception) {
                if (token == generation) Log.w("SPlayer", "系统封面加载失败", error)
            } finally {
                request?.disconnect()
                if (connection === request) connection = null
                temporary?.delete()
            }
        }
    }
}
