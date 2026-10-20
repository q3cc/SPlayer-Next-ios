package app.tauri.nativeaudio

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import app.tauri.annotation.InvokeArg
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

@InvokeArg
class LastfmCredentialArgs {
    lateinit var action: String
    var value: String? = null
    var namespace: String? = null
}

/** 密钥留在 Android Keystore，密文不参与系统备份。 */
internal class LastfmCredentials(private val context: Context) {
    private var file = File(context.noBackupFilesDir, "lastfm-session")
    private var alias = "splayer.lastfm"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(alias, null) as? SecretKey
        if (existing != null) return existing
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    @Synchronized fun run(args: LastfmCredentialArgs): String? {
        require(args.namespace == null || args.namespace == "aiModels") { "未知凭证类型" }
        file = File(context.noBackupFilesDir, if (args.namespace == "aiModels") "ai-models" else "lastfm-session")
        alias = if (args.namespace == "aiModels") "splayer.ai-models" else "splayer.lastfm"
        when (args.action) {
            "get" -> {
                if (!file.exists()) return null
                val parts = file.readText().split(":")
                require(parts.size == 2)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
                return String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8)
            }
            "set" -> {
                val value = requireNotNull(args.value)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, key())
                val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
                val temporary = File(file.parentFile, file.name + ".tmp")
                temporary.writeText(Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(encrypted, Base64.NO_WRAP))
                check(temporary.renameTo(file)) { "无法保存 Last.fm 凭证" }
            }
            "clear" -> check(!file.exists() || file.delete()) { "无法删除 Last.fm 凭证" }
            else -> error("未知凭证操作")
        }
        return null
    }
}
