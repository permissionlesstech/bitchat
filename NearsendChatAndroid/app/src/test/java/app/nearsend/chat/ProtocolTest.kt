package app.nearsend.chat

import org.junit.Assert.*
import org.junit.Test

/** Mirrors NearsendChatiOS/Tests/main.swift: same vectors, same relay scenarios. */
class ProtocolTest {
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun toHex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    private val skA = hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
    private val skB = hex("65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081828384")
    private val combined = hex("c8c9cacbcccdcecfd0d1d2d3b7f7d3789adc70b46a831626878bc5809086ac2253d1ba553d06af4445a5b4c525")

    @Test fun cryptoMatchesPythonVector() {
        val a = MeshCrypto(skA); val b = MeshCrypto(skB)
        assertEquals("07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c", toHex(a.publicKey))
        assertEquals("Hej världen 👋", b.open(combined, a.publicKey, "bob", "alice", "m-1"))
        assertEquals("Hej världen 👋", a.open(combined, b.publicKey, "alice", "bob", "m-1"))
        assertEquals("AAA8 FFF7 03B5 0B22\n97F4 F6E1 3508 F724", a.fingerprint)
    }

    @Test fun cryptoRejectsTamperingAndWrongContext() {
        val a = MeshCrypto(skA); val b = MeshCrypto(skB)
        assertThrows(Exception::class.java) { b.open(combined, a.publicKey, "bob", "alice", "other") }
        val t = combined.copyOf(); t[20] = (t[20].toInt() xor 1).toByte()
        assertThrows(Exception::class.java) { b.open(t, a.publicKey, "bob", "alice", "m-1") }
    }

    @Test fun sealThenOpenRoundTrips() {
        val a = MeshCrypto.generate(); val b = MeshCrypto.generate()
        val ct = a.seal("hej", b.publicKey, "a", "b", "id")
        assertEquals("hej", b.open(ct, a.publicKey, "b", "a", "id"))
    }

    @Test fun clipsToUtf8Bytes() {
        assertTrue(MeshRouter.clip("å".repeat(200)).toByteArray().size <= 180)
        assertEquals("hej", MeshRouter.clip("hej"))
    }

    // ---- simulated networks

    private class Node(val id: String, net: Net) {
        val crypto = MeshCrypto.generate()
        val router = MeshRouter(id, id, crypto)
        val texts = mutableListOf<Triple<String, String, Int>>(); val pubs = mutableListOf<String>(); val delivered = mutableListOf<String>()
        var peers = listOf<Peer>()
        init {
            router.transmit = { link, data, done -> net.deliver(id, link, data); done(true) }
            router.onPeers = { peers = it }
            router.onText = { f, _, t, h, _ -> texts += Triple(f, t, h) }
            router.onPublic = { _, _, t, _ -> pubs += t }
            router.onDelivered = { delivered += it }
        }
    }

    private class Net {
        val nodes = LinkedHashMap<String, Node>()
        fun add(id: String) = Node(id, this).also { nodes[id] = it }
        fun deliver(from: String, to: String, data: ByteArray) { nodes[to]?.router?.receive(data, from) }
        fun connect(x: String, y: String) {
            nodes[x]!!.router.neighborConnected(y, y, y, nodes[y]!!.crypto.publicKey)
            nodes[y]!!.router.neighborConnected(x, x, x, nodes[x]!!.crypto.publicKey)
        }
        fun settle() { repeat(3) { nodes.values.forEach { it.router.tick() } } }
    }

    @Test fun lineOfFourDeliversEncryptedAcrossThreeHops() {
        val net = Net(); val n = listOf("A", "B", "C", "D").map { net.add(it) }
        net.connect("A", "B"); net.connect("B", "C"); net.connect("C", "D"); net.settle()
        assertEquals(3, n[0].peers.first { it.id == "D" }.hops)
        var outcome: SendOutcome? = null
        n[0].router.sendText("hello D", "D", "id-1") { outcome = it }
        assertEquals(SendOutcome.Sent, outcome)
        assertEquals(listOf(Triple("A", "hello D", 3)), n[3].texts)
        assertEquals(listOf("id-1"), n[0].delivered)
        assertTrue(n[1].texts.isEmpty() && n[2].texts.isEmpty())
        n[0].router.sendPublic("hi all", "pub-1") { }
        assertEquals(listOf("hi all"), n[1].pubs); assertEquals(listOf("hi all"), n[3].pubs)
    }

    @Test fun ttlLimitsReachToFiveHops() {
        val net = Net(); val ids = (0 until 8).map { "N$it" }; val n = ids.map { net.add(it) }
        for (i in 0 until 7) net.connect(ids[i], ids[i + 1]); net.settle()
        assertEquals(setOf("N1", "N2", "N3", "N4", "N5"), n[0].peers.map { it.id }.toSet())
        var outcome: SendOutcome? = null
        n[0].router.sendText("far", "N7", "id-far") { outcome = it }
        assertEquals(SendOutcome.Unreachable, outcome)
    }

    @Test fun loopsDoNotDuplicate() {
        val net = Net(); val n = listOf("A", "B", "C").map { net.add(it) }
        net.connect("A", "B"); net.connect("B", "C"); net.connect("C", "A"); net.settle()
        n[0].router.sendText("once", "C", "id-tri") { }
        n[0].router.sendPublic("loop", "pub-tri") { }
        assertEquals(1, n[2].texts.size)
        assertEquals(1, n[1].pubs.size); assertEquals(1, n[2].pubs.size)
    }

    @Test fun peersExpireAndNeighboursDrop() {
        val net = Net(); val n = listOf("A", "B", "C").map { net.add(it) }
        net.connect("A", "B"); net.connect("B", "C"); net.settle()
        assertEquals(2, n[0].peers.size)
        var t = System.currentTimeMillis(); n[0].router.now = { t }; t += 60_000; n[0].router.tick()
        assertEquals(listOf("B"), n[0].peers.map { it.id })
        n[0].router.neighborLost("B")
        assertTrue(n[0].peers.isEmpty())
    }

    @Test fun packetsInteroperateWithIosJson() {
        // A packet exactly as the iOS JSONEncoder writes it (keys in a different order, optional fields absent).
        val json = """{"ts":1700000000000,"ttl":4,"t":"pub","src":"IOS-1","v":2,"id":"p-1","tx":"hej","n":"Ios"}"""
        val p = Packet.parse(json.toByteArray())!!
        assertEquals("pub", p.t); assertEquals("hej", p.tx); assertNull(p.dst); assertEquals(4, p.ttl)
    }
}
