package app.nearsend.chat

import com.google.crypto.tink.subtle.ChaCha20Poly1305
import com.google.crypto.tink.subtle.Hkdf
import com.google.crypto.tink.subtle.X25519
import java.security.MessageDigest

/**
 * End-to-end encryption for direct messages (see PROTOCOL.md), identical to the iOS implementation.
 * X25519 key agreement -> HKDF-SHA256 -> ChaCha20-Poly1305. Sealed message = nonce(12) || ciphertext || tag(16).
 */
class MeshCrypto(private val privateKey: ByteArray) {
    val publicKey: ByteArray = X25519.publicFromPrivate(privateKey)
    val privateKeyBytes: ByteArray get() = privateKey.copyOf()
    val fingerprint: String get() = fingerprint(publicKey)

    companion object {
        fun generate() = MeshCrypto(X25519.generatePrivateKey())

        /** First 128 bits of SHA-256(public key), 8 groups of 4 hex digits on two lines. */
        fun fingerprint(publicKey: ByteArray): String {
            val hex = MessageDigest.getInstance("SHA-256").digest(publicKey).joinToString("") { "%02X".format(it) }
            val groups = (0 until 8).map { hex.substring(it * 4, it * 4 + 4) }
            return groups.take(4).joinToString(" ") + "\n" + groups.drop(4).joinToString(" ")
        }
    }

    private fun key(peerPk: ByteArray, myId: String, peerId: String): ByteArray {
        require(peerPk.size == 32) { "bad public key" }
        val secret = X25519.computeSharedSecret(privateKey, peerPk)
        val info = listOf(myId, peerId).sorted().joinToString("|")
        return Hkdf.computeHkdf("HmacSha256", secret, "nearsend-chat-v2".toByteArray(), info.toByteArray(), 32)
    }

    fun seal(text: String, peerPk: ByteArray, myId: String, peerId: String, aad: String): ByteArray =
        ChaCha20Poly1305(key(peerPk, myId, peerId)).encrypt(text.toByteArray(), aad.toByteArray())

    fun open(combined: ByteArray, peerPk: ByteArray, myId: String, peerId: String, aad: String): String =
        String(ChaCha20Poly1305(key(peerPk, myId, peerId)).decrypt(combined, aad.toByteArray()))
}
