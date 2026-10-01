package app.tauri.nativeaudio

import android.content.pm.PackageManager
import android.media.browse.MediaBrowser
import android.os.Bundle
import android.os.Process
import android.service.media.MediaBrowserService

/** 将正在播放的会话注册到系统媒体浏览入口，不另建播放器或复制曲库。 */
class NativeMediaBrowserService : MediaBrowserService() {
    private val engine by lazy { AudioEngine.get(this) }

    override fun onCreate() {
        super.onCreate()
        sessionToken = engine.sessionToken
    }

    override fun onGetRoot(clientPackageName: String, clientUid: Int, rootHints: Bundle?): BrowserRoot? {
        val packages = packageManager.getPackagesForUid(clientUid) ?: return null
        if (!packages.contains(clientPackageName)) return null
        val trusted = clientUid == Process.SYSTEM_UID || clientUid == applicationInfo.uid ||
            packageManager.checkPermission("android.permission.MEDIA_CONTENT_CONTROL", clientPackageName) == PackageManager.PERMISSION_GRANTED
        return if (trusted) BrowserRoot("splayer-current", null) else null
    }

    override fun onLoadChildren(parentId: String, result: Result<MutableList<MediaBrowser.MediaItem>>) {
        result.sendResult(if (parentId == "splayer-current") {
            engine.currentMediaItem()?.let { mutableListOf(it) } ?: mutableListOf()
        } else mutableListOf())
    }
}
