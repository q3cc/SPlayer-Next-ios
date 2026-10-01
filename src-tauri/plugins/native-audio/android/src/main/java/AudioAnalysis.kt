package app.tauri.nativeaudio

import android.media.audiofx.Visualizer
import app.tauri.plugin.JSObject
import org.json.JSONArray
import kotlin.math.*

@app.tauri.annotation.InvokeArg
class ProcessingArgs {
    var fadeDuration: Double = 0.0
    var normalization: Boolean = false
    var fftEnabled: Boolean = false
}

/** 只采集本播放器会话；关闭频谱或隐藏窗口时停止相应采集。 */
internal class AudioAnalysis(session: Int, private val spectrum: (JSObject) -> Unit,
                             private val normalized: (Double) -> Unit) {
    private val visualizer = Visualizer(session)
    private var gain = 1.0
    private var lastAnalysis = 0L
    private var normalize = false
    private var fft = false
    var latest = JSObject().apply {
        put("ldata", JSONArray(List(64) { 0.0 })); put("rdata", JSONArray(List(64) { 0.0 }))
    }
        private set

    init {
        try {
            val range = Visualizer.getCaptureSizeRange()
            visualizer.captureSize = 1024.coerceIn(range[0], range[1])
            visualizer.scalingMode = Visualizer.SCALING_MODE_AS_PLAYED
        } catch (error: Exception) {
            visualizer.release()
            throw error
        }
    }

    fun configure(normalization: Boolean, spectrumEnabled: Boolean) {
        visualizer.enabled = false
        normalize = normalization
        fft = spectrumEnabled
        if (!normalize) { gain = 1.0; normalized(gain) }
        val status = visualizer.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
            override fun onWaveFormDataCapture(source: Visualizer, waveform: ByteArray, samplingRate: Int) {
                if (!normalize) return
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - lastAnalysis < 400) return
                lastAnalysis = now
                var energy = 0.0
                var peak = 0.0
                for (byte in waveform) {
                    val value = ((byte.toInt() and 255) - 128) / 128.0 / gain
                    energy += value * value
                    peak = max(peak, abs(value))
                }
                val rms = sqrt(energy / waveform.size.coerceAtLeast(1))
                if (rms > 0.001) {
                    val target = min((0.2 / rms).coerceIn(0.1, 3.0), 0.95 / peak.coerceAtLeast(0.001))
                    gain += (target - gain) * if (target < gain) 0.4 else 0.08
                    normalized(gain)
                }
            }
            override fun onFftDataCapture(source: Visualizer, data: ByteArray, samplingRate: Int) {
                if (!fft) return
                val bins = data.size / 2
                val values = List(64) { band ->
                    val start = max(1, bins.toDouble().pow(band / 64.0).toInt())
                    val end = max(start + 1, bins.toDouble().pow((band + 1) / 64.0).toInt())
                    var magnitude = 0.0
                    for (bin in start until min(end, data.size / 2)) {
                        magnitude = max(magnitude, hypot(data[bin * 2].toDouble(), data[bin * 2 + 1].toDouble()) / 128)
                    }
                    ((20 * log10(magnitude.coerceAtLeast(0.000001)) + 60) / 60).coerceIn(0.0, 1.0)
                }
                latest = JSObject().apply { put("ldata", JSONArray(values)); put("rdata", JSONArray(values)) }
                spectrum(latest)
            }
        }, min(Visualizer.getMaxCaptureRate(), if (fft) 30000 else 5000), normalize, fft)
        check(status == Visualizer.SUCCESS) { "无法开启音频分析" }
        visualizer.enabled = normalize || fft
    }

    fun release() { normalize = false; fft = false; visualizer.enabled = false; visualizer.release() }
}
