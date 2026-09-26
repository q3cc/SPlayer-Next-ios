package app.tauri.nativeaudio

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.database.ContentObserver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.media.MediaMetadata
import android.media.MediaPlayer
import android.media.PlaybackParams
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import java.io.File

@InvokeArg
class SourceArgs {
    lateinit var source: String
    var autoPlay: Boolean = true
    var trackId: String? = null
}

@InvokeArg
class ControlArgs {
    lateinit var action: String
    var position: Double? = null
}

@InvokeArg
class EffectArgs {
    var volume: Double = 1.0
    var speed: Double = 1.0
    var pitch: Double = 0.0
    var pitchSync: Boolean = true
    var enabled: Boolean = false
    var bands: DoubleArray = DoubleArray(10)
    var preamp: Double = 0.0
}

class LyricLineArgs {
    var start: Long = 0
    var end: Long = 0
    var text: String = ""
}

@InvokeArg
class MetadataArgs {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var cover: String = ""
    var enabled: Boolean = true
    var dynamic: Boolean = false
    var offset: Long = 0
    var lines: Array<LyricLineArgs> = emptyArray()
}

@InvokeArg
class VolumeArgs {
    var value: Double? = null
    var show: Boolean? = null
}

@InvokeArg
class FileArgs {
    lateinit var path: String
}

/** One process-wide player survives WebView recreation and owns the Android media session. */
internal class AudioEngine private constructor(private val context: Context) {
    companion object {
        @Volatile private var instance: AudioEngine? = null
        fun get(context: Context): AudioEngine = instance ?: synchronized(this) {
            instance ?: AudioEngine(context.applicationContext).also { instance = it }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val session = MediaSession(context, "SPlayer Next")
    private var player: MediaPlayer? = null
    private var equalizer: Equalizer? = null
    private var loudness: LoudnessEnhancer? = null
    private var prepared = false
    private var playOnPrepared = false
    private var state = "idle"
    private var finished = false
    private var speed = 1.0
    private var pitch = 0.0
    private var effects = EffectArgs()
    private var metadata: MetadataArgs? = null
    private var displayedTitle = ""
    private var pending: Invoke? = null
    private var loadTimeout: Runnable? = null
    private var focusRequest: AudioFocusRequest? = null
    private val legacyFocusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK) {
            if (state == "playing") controlFromSystem("pause")
        }
    }
    var emit: ((String, JSObject) -> Unit)? = null
    private val positionTicker = object : Runnable {
        override fun run() {
            if (state != "playing") return
            emit?.invoke("position", snapshot())
            publishMetadata()
            handler.postDelayed(this, 1000)
        }
    }

    init {
        session.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() { controlFromSystem("play") }
            override fun onPause() { controlFromSystem("pause") }
            override fun onStop() { controlFromSystem("stop") }
            override fun onSeekTo(pos: Long) { controlFromSystem("seek", pos.toDouble()) }
            override fun onSkipToNext() { emit?.invoke("action", JSObject().apply { put("type", "next") }) }
            override fun onSkipToPrevious() { emit?.invoke("action", JSObject().apply { put("type", "prev") }) }
        }, handler)
        session.isActive = true
        context.contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true,
            object : ContentObserver(handler) {
                override fun onChange(selfChange: Boolean) {
                    emit?.invoke("systemVolume", JSObject().apply { put("volume", systemVolume()) })
                }
            })
        publishState()
    }

    private fun systemVolume(): Double =
        audioManager.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() /
            audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)

    private fun requestFocus(): Boolean {
        val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
        return if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener(legacyFocusListener, handler).build()
            focusRequest = request
            audioManager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(legacyFocusListener, AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonFocus() {
        if (Build.VERSION.SDK_INT >= 26) focusRequest?.let(audioManager::abandonAudioFocusRequest)
        else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(legacyFocusListener)
        }
        focusRequest = null
    }

    private fun position(): Long = if (prepared) {
        try { player?.currentPosition?.toLong() ?: 0L } catch (_: Exception) { 0L }
    } else 0L

    private fun duration(): Long = if (prepared) {
        try { player?.duration?.toLong()?.coerceAtLeast(0) ?: 0L } catch (_: Exception) { 0L }
    } else 0L

    fun snapshot(): JSObject = JSObject().apply {
        put("state", state)
        put("position", position())
        put("duration", duration())
        put("volume", systemVolume())
        put("speed", speed)
        put("isFinished", finished)
    }

    private fun publishState() {
        val nativeState = when (state) {
            "playing" -> PlaybackState.STATE_PLAYING
            "paused" -> PlaybackState.STATE_PAUSED
            "loading" -> PlaybackState.STATE_BUFFERING
            "stopped" -> PlaybackState.STATE_STOPPED
            else -> PlaybackState.STATE_NONE
        }
        session.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP or
                PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_SKIP_TO_NEXT or
                PlaybackState.ACTION_SKIP_TO_PREVIOUS)
            .setState(nativeState, position(), if (state == "playing") speed.toFloat() else 0f)
            .build())
        emit?.invoke("state", snapshot())
        handler.removeCallbacks(positionTicker)
        if (state == "playing") handler.postDelayed(positionTicker, 1000)
        if (state == "playing" || state == "paused") NativeAudioService.current?.updateNotification()
    }

    private fun service(action: String) {
        val intent = Intent(context, NativeAudioService::class.java).setAction(action)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
    }

    private fun reset() {
        loadTimeout?.let(handler::removeCallbacks)
        loadTimeout = null
        pending?.reject("已切换歌曲")
        pending = null
        loudness?.release()
        loudness = null
        equalizer?.release()
        equalizer = null
        player?.release()
        player = null
        prepared = false
        playOnPrepared = false
        finished = false
    }

    fun load(args: SourceArgs, invoke: Invoke) {
        abandonFocus()
        reset()
        playOnPrepared = args.autoPlay
        state = "loading"
        publishState()
        try {
            val mediaPlayer = MediaPlayer()
            mediaPlayer.setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            mediaPlayer.setWakeMode(context, PowerManager.PARTIAL_WAKE_LOCK)
            when {
                args.source.startsWith("content:") -> mediaPlayer.setDataSource(context, Uri.parse(args.source))
                args.source.startsWith("file:") -> mediaPlayer.setDataSource(Uri.parse(args.source).path!!)
                else -> mediaPlayer.setDataSource(args.source)
            }
            player = mediaPlayer
            pending = invoke
            mediaPlayer.setOnPreparedListener {
                if (player !== it) return@setOnPreparedListener
                loadTimeout?.let(handler::removeCallbacks)
                loadTimeout = null
                prepared = true
                state = "paused"
                try {
                    equalizer = Equalizer(0, it.audioSessionId).apply { enabled = false }
                } catch (_: Exception) { equalizer = null }
                try {
                    loudness = LoudnessEnhancer(it.audioSessionId).apply { enabled = true }
                } catch (_: Exception) { loudness = null }
                try {
                    applyEffects()
                    publishMetadata(true)
                    if (playOnPrepared) control("play", null) else publishState()
                    pending?.resolve(snapshot())
                    pending = null
                } catch (error: Exception) {
                    val failed = pending
                    pending = null
                    reset()
                    state = "idle"
                    publishState()
                    failed?.reject(error.message ?: "无法播放音频")
                }
            }
            mediaPlayer.setOnCompletionListener {
                if (player !== it) return@setOnCompletionListener
                state = "stopped"
                finished = true
                publishState()
                emit?.invoke("ended", JSObject())
                NativeAudioService.current?.stopPlayback()
                abandonFocus()
            }
            mediaPlayer.setOnErrorListener { source, what, extra ->
                if (player === source) {
                    val message = "Android audio error $what/$extra"
                    state = "idle"
                    val failed = pending
                    pending = null
                    reset()
                    publishState()
                    failed?.reject(message)
                    emit?.invoke("error", JSObject().apply { put("message", message) })
                }
                true
            }
            mediaPlayer.prepareAsync()
            loadTimeout = Runnable {
                if (player !== mediaPlayer || pending == null) return@Runnable
                val failed = pending
                pending = null
                reset()
                state = "idle"
                publishState()
                failed?.reject("原生音频加载超时")
            }.also { handler.postDelayed(it, 25_000) }
        } catch (error: Exception) {
            pending = null
            reset()
            state = "idle"
            publishState()
            invoke.reject(error.message ?: "无法播放音频")
        }
    }

    fun control(action: String, positionMs: Double?): JSObject {
        val current = player
        when (action) {
            "play" -> {
                if (state == "loading") playOnPrepared = true
                else {
                    if (!prepared || current == null) throw IllegalStateException("请先选择一首歌曲")
                    if (state != "playing") {
                        if (!requestFocus()) throw IllegalStateException("音频设备暂时不可用")
                        applyPlaybackParams()
                        current.start()
                        state = "playing"
                        finished = false
                        service(NativeAudioService.START)
                    }
                }
            }
            "pause" -> {
                if (state == "loading") playOnPrepared = false
                else if (prepared && current != null && state == "playing") {
                    current.pause()
                    state = "paused"
                    abandonFocus()
                }
            }
            "stop" -> {
                reset()
                state = "stopped"
                abandonFocus()
                NativeAudioService.current?.stopPlayback()
            }
            "seek" -> {
                if (!prepared || current == null || positionMs?.isFinite() != true)
                    throw IllegalStateException("当前音源暂不支持跳转")
                current.seekTo(positionMs.toLong().coerceIn(0L, duration()).toInt())
            }
            else -> throw IllegalArgumentException("未知播放操作")
        }
        publishState()
        return snapshot()
    }

    fun hasSource(): Boolean = player != null

    fun controlFromSystem(action: String, positionMs: Double? = null) {
        if ((action == "play" || action == "seek") && !prepared && state != "loading") return
        try {
            control(action, positionMs)
        } catch (error: Exception) {
            emit?.invoke("error", JSObject().apply {
                put("message", error.message ?: "系统播放操作失败")
            })
        }
    }

    fun configure(args: EffectArgs) {
        require(args.volume.isFinite() && args.volume in 0.0..1.0)
        require(args.speed.isFinite() && args.speed in 0.5..2.0)
        require(args.pitch.isFinite() && args.pitch in -12.0..12.0)
        require(args.preamp.isFinite() && args.preamp in -12.0..12.0)
        require(args.bands.size == 10 && args.bands.all { it.isFinite() && it in -15.0..15.0 })
        if (prepared && args.enabled && equalizer == null)
            throw IllegalStateException("此设备不支持系统均衡器")
        effects = args
        speed = args.speed
        pitch = args.pitch
        if (prepared && state == "playing") applyPlaybackParams()
        applyEffects()
        publishState()
    }

    private fun applyPlaybackParams() {
        if (!prepared) return
        player?.playbackParams = PlaybackParams().setSpeed(speed.toFloat())
            .setPitch(if (effects.pitchSync) Math.pow(2.0, pitch / 12.0).toFloat() else speed.toFloat())
    }

    private fun applyEffects() {
        if (!prepared) return
        val preamp = if (effects.enabled) effects.preamp else 0.0
        val attenuation = Math.pow(10.0, preamp.coerceAtMost(0.0) / 20.0)
        val volume = (effects.volume * attenuation).toFloat().coerceIn(0f, 1f)
        player?.setVolume(volume, volume)
        loudness?.setTargetGain((preamp.coerceAtLeast(0.0) * 1000).toInt())
        equalizer?.let { effect ->
            effect.enabled = effects.enabled
            if (effects.enabled) {
                val range = effect.bandLevelRange
                for (index in 0 until effect.numberOfBands) {
                    val frequency = effect.getCenterFreq(index.toShort()) / 1000.0
                    val source = (0..9).minByOrNull {
                        kotlin.math.abs(kotlin.math.ln(sourceFrequency(it) / frequency.coerceAtLeast(1.0)))
                    } ?: 0
                    val gain = (effects.bands[source] * 100).toInt().coerceIn(range[0].toInt(), range[1].toInt())
                    effect.setBandLevel(index.toShort(), gain.toShort())
                }
            }
        }
    }

    private fun sourceFrequency(index: Int): Double =
        doubleArrayOf(32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0)[index]

    fun setMetadata(args: MetadataArgs) {
        metadata = if (args.enabled) args else null
        publishMetadata(true)
    }

    private fun publishMetadata(force: Boolean = false) {
        val info = metadata
        val time = position() + (info?.offset ?: 0L)
        val lyric = if (info?.dynamic == true) info.lines.lastOrNull {
            it.start <= time && time < it.end + 3000 && it.text.isNotBlank()
        } else null
        val title = lyric?.text ?: info?.title.orEmpty()
        if (!force && title == displayedTitle) return
        displayedTitle = title
        val builder = MediaMetadata.Builder()
        if (info != null) {
            builder.putString(MediaMetadata.METADATA_KEY_TITLE, title)
            builder.putString(MediaMetadata.METADATA_KEY_ARTIST, if (lyric != null)
                listOf(info.title, info.artist).filter { it.isNotBlank() }.joinToString(" - ")
                else info.artist)
            builder.putString(MediaMetadata.METADATA_KEY_ALBUM, if (lyric != null) "" else info.album)
            builder.putLong(MediaMetadata.METADATA_KEY_DURATION, duration())
            if (info.cover.isNotBlank()) builder.putString(MediaMetadata.METADATA_KEY_ART_URI, info.cover)
        }
        session.setMetadata(builder.build())
        if (state == "playing" || state == "paused") NativeAudioService.current?.updateNotification()
    }

    fun notification(): Notification {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel("splayer-playback", "Music playback",
                NotificationManager.IMPORTANCE_LOW))
            Notification.Builder(context, "splayer-playback")
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(Notification.PRIORITY_LOW)
        }
        fun action(label: String, icon: Int, command: String): Notification.Action {
            val intent = Intent(context, NativeAudioService::class.java).setAction(command)
            val pending = PendingIntent.getService(context, command.hashCode(), intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            return Notification.Action.Builder(icon, label, pending).build()
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val content = launch?.let { PendingIntent.getActivity(context, 0, it,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE) }
        val info = metadata
        return builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(displayedTitle.ifBlank { "SPlayer Next" })
            .setContentText(info?.artist ?: "")
            .setContentIntent(content)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .addAction(action("Previous", android.R.drawable.ic_media_previous, NativeAudioService.PREV))
            .addAction(action(if (state == "playing") "Pause" else "Play",
                if (state == "playing") android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                if (state == "playing") NativeAudioService.PAUSE else NativeAudioService.PLAY))
            .addAction(action("Next", android.R.drawable.ic_media_next, NativeAudioService.NEXT))
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0, 1, 2))
            .build()
    }

    fun readMetadata(source: String): JSObject {
        val retriever = MediaMetadataRetriever()
        try {
            if (source.startsWith("content:")) retriever.setDataSource(context, Uri.parse(source))
            else retriever.setDataSource(if (source.startsWith("file:")) Uri.parse(source).path else source)
            return JSObject().apply {
                put("title", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE) ?: "")
                put("artist", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST) ?: "")
                put("album", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM) ?: "")
                put("duration", retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L)
                put("externalLyrics", emptyList<Any>())
            }
        } finally { retriever.release() }
    }

    fun readLyrics(path: String): String = if (path.startsWith("content:"))
        context.contentResolver.openInputStream(Uri.parse(path))?.bufferedReader()?.use { it.readText() }
            ?: throw IllegalArgumentException("歌词文件无法读取")
    else File(if (path.startsWith("file:")) Uri.parse(path).path!! else path).readText()
}

class NativeAudioService : Service() {
    companion object {
        const val START = "splayer.audio.START"
        const val PLAY = "splayer.audio.PLAY"
        const val PAUSE = "splayer.audio.PAUSE"
        const val NEXT = "splayer.audio.NEXT"
        const val PREV = "splayer.audio.PREV"
        var current: NativeAudioService? = null
    }

    private val engine by lazy { AudioEngine.get(this) }

    override fun onCreate() {
        super.onCreate()
        current = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = engine.notification()
        if (Build.VERSION.SDK_INT >= 29)
            startForeground(42, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        else startForeground(42, notification)
        if (!engine.hasSource()) {
            stopPlayback()
            return START_NOT_STICKY
        }
        when (intent?.action) {
            PLAY -> engine.controlFromSystem("play")
            PAUSE -> engine.controlFromSystem("pause")
            NEXT -> engine.emit?.invoke("action", JSObject().apply { put("type", "next") })
            PREV -> engine.emit?.invoke("action", JSObject().apply { put("type", "prev") })
        }
        return START_NOT_STICKY
    }

    fun updateNotification() {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(42, engine.notification())
    }

    fun stopPlayback() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        current = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

@TauriPlugin
class NativeAudioPlugin(private val activity: Activity) : Plugin(activity) {
    private val engine by lazy { AudioEngine.get(activity) }
    private val handler = Handler(Looper.getMainLooper())

    override fun load(webView: android.webkit.WebView) {
        super.load(webView)
        engine.emit = { name, data -> trigger(name, data) }
    }

    @Command fun load(invoke: Invoke) {
        val args = invoke.parseArgs(SourceArgs::class.java)
        handler.post { engine.load(args, invoke) }
    }

    @Command fun control(invoke: Invoke) {
        val args = invoke.parseArgs(ControlArgs::class.java)
        handler.post {
            try { invoke.resolve(engine.control(args.action, args.position)) }
            catch (error: Exception) { invoke.reject(error.message ?: "播放操作失败") }
        }
    }

    @Command fun configure(invoke: Invoke) {
        val args = invoke.parseArgs(EffectArgs::class.java)
        handler.post {
            try { engine.configure(args); invoke.resolve() }
            catch (error: Exception) { invoke.reject(error.message ?: "音效设置失败") }
        }
    }

    @Command fun metadata(invoke: Invoke) {
        val args = invoke.parseArgs(MetadataArgs::class.java)
        handler.post { engine.setMetadata(args); invoke.resolve() }
    }

    @Command fun status(invoke: Invoke) { handler.post { invoke.resolve(engine.snapshot()) } }
    @Command fun visibility(invoke: Invoke) { invoke.resolve() }

    @Command fun systemVolume(invoke: Invoke) {
        val args = invoke.parseArgs(VolumeArgs::class.java)
        handler.post {
            val manager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val max = manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
            args.value?.let { manager.setStreamVolume(AudioManager.STREAM_MUSIC,
                (it.coerceIn(0.0, 1.0) * max).toInt(), 0) }
            invoke.resolve(JSObject().apply {
                put("volume", manager.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max)
            })
        }
    }

    @Command fun readMetadata(invoke: Invoke) {
        val args = invoke.parseArgs(SourceArgs::class.java)
        Thread {
            try { invoke.resolve(engine.readMetadata(args.source)) }
            catch (error: Exception) { invoke.reject(error.message ?: "无法读取音频信息") }
        }.start()
    }

    @Command fun readLyricFile(invoke: Invoke) {
        val args = invoke.parseArgs(FileArgs::class.java)
        Thread {
            try { invoke.resolveObject(engine.readLyrics(args.path)) }
            catch (error: Exception) { invoke.reject(error.message ?: "无法读取歌词") }
        }.start()
    }
}
