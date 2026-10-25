package app.nearsend.chat

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

private fun timeOf(ms: Long): String = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ms))

// ───────────────────────── Onboarding ─────────────────────────

private class OnboardPage(val icon: ImageVector, val title: String, val body: String)

@Composable
fun OnboardingScreen(onDone: () -> Unit) {
    val pages = remember {
        listOf(
            OnboardPage(Icons.Filled.Sensors, "Chat without internet", "Messages hop phone to phone over Bluetooth. No signal, no SIM, no account."),
            OnboardPage(Icons.Filled.Hub, "Every phone is a relay", "The more people nearby, the further your message travels."),
            OnboardPage(Icons.Filled.Lock, "Private by design", "Nothing is stored on a server. End-to-end encryption is on the roadmap."),
        )
    }
    val pager = rememberPagerState { pages.size }
    val scope = rememberCoroutineScope()
    val pulse by rememberInfiniteTransition(label = "pulse").animateFloat(
        0.95f, 1.1f, infiniteRepeatable(tween(2200, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "p",
    )
    Column(Modifier.fillMaxSize().systemBarsPadding().padding(bottom = 24.dp)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("NEARSEND", fontFamily = Anton, fontSize = 22.sp, color = Color.White)
            Spacer(Modifier.weight(1f))
            Text("Early development", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.background(SkyPillColor, CircleShape).padding(horizontal = 14.dp, vertical = 8.dp))
        }
        HorizontalPager(pager, Modifier.weight(1f)) { i ->
            val pg = pages[i]
            Column(Modifier.fillMaxSize().padding(horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Box(Modifier.height(270.dp), contentAlignment = Alignment.Center) {
                    for (r in 0 until 3) {
                        val d = (130 + r * 56).dp
                        Canvas(Modifier.size(d * pulse)) { drawCircle(Color.White.copy(alpha = 0.5f - r * 0.14f), style = Stroke(1.dp.toPx())) }
                    }
                    Box(Modifier.size(112.dp).glass(56.dp), contentAlignment = Alignment.Center) {
                        Icon(pg.icon, null, tint = ActionBlue, modifier = Modifier.size(46.dp))
                    }
                }
                Spacer(Modifier.height(28.dp))
                Text(pg.title.uppercase(), fontFamily = Anton, fontSize = 40.sp, color = Color.White, textAlign = TextAlign.Center, lineHeight = 44.sp)
                Spacer(Modifier.height(16.dp))
                SkyPill { Text(pg.body, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center) }
            }
        }
        Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalArrangement = Arrangement.Center) {
            for (i in pages.indices) Box(Modifier.padding(4.dp).size(8.dp).background(Color.White.copy(alpha = if (i == pager.currentPage) 1f else 0.4f), CircleShape))
        }
        PrimaryButton(if (pager.currentPage == pages.size - 1) "Allow Bluetooth & start" else "Continue", Modifier.padding(horizontal = 24.dp)) {
            if (pager.currentPage == pages.size - 1) onDone() else scope.launch { pager.animateScrollToPage(pager.currentPage + 1) }
        }
    }
}

// ───────────────────────── Nearby + radar ─────────────────────────

@Composable
fun NearbyScreen(store: ChatStore, onOpenChat: (Peer) -> Unit) {
    val p = LocalPalette.current
    val statusOk = store.meshActive && (store.simulated || store.bluetoothState == "ready")
    val statusText = when {
        !store.meshActive -> "Mesh paused"
        store.simulated -> "Demo data · emulator"
        else -> when (store.bluetoothState) {
            "ready" -> "Bluetooth live · offline"
            "off" -> "Bluetooth is off"
            "unauthorized" -> "Bluetooth not allowed"
            "unsupported" -> "Bluetooth unsupported"
            else -> "Starting Bluetooth…"
        }
    }
    val subtitle = when {
        !store.simulated && store.bluetoothState == "unauthorized" -> "Allow Bluetooth for Nearsend Chat in Settings"
        !store.simulated && store.bluetoothState == "off" -> "Turn Bluetooth on to find people nearby"
        !store.simulated && store.peers.isEmpty() -> "Open the app on another phone to connect"
        else -> "${store.relayedCount} reachable via relay"
    }
    LazyColumn(Modifier.fillMaxSize().statusBarsPadding(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { PageTitle("Nearby") }
        item {
            Card {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        StatusPill(statusText, if (statusOk) p.secure else p.inkSecondary)
                        Text("${store.peers.size} ${if (store.peers.size == 1) "person" else "people"} in range", color = p.ink, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                        Text(subtitle, color = p.inkSecondary, fontSize = 13.sp)
                    }
                    Switch(store.meshActive, { store.setMesh(it) }, colors = SwitchDefaults.colors(checkedTrackColor = ActionBlue, checkedThumbColor = Color.White))
                }
            }
        }
        item { Card(padding = 12.dp) { Radar(store.peers, Modifier.fillMaxWidth().height(320.dp)) } }
        items(store.peers.sortedByDescending { it.rssi }, key = { it.id }) { peer ->
            Card(Modifier.clickable { onOpenChat(peer) }, padding = 12.dp) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Avatar(peer.name, online = true)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(peer.name, color = p.ink, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                            if (peer.verified) Icon(Icons.Filled.Verified, null, tint = ActionBlue, modifier = Modifier.size(15.dp))
                        }
                        Text(if (peer.hops == 1) "Direct · ${peer.rssi} dBm" else "${peer.hops} hops via relay", color = p.inkSecondary, fontSize = 13.sp)
                    }
                    SignalBars(peer.rssi)
                }
            }
        }
    }
}

private fun radiusFor(p: Peer) = ((-40 - p.rssi) / 55f).coerceIn(0.18f, 1f)
private fun angleFor(p: Peer) = (abs(p.id.hashCode()) % 360) * Math.PI.toFloat() / 180f

@Composable
fun Radar(peers: List<Peer>, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val rot by rememberInfiniteTransition(label = "sweep").animateFloat(
        0f, 360f, infiniteRepeatable(tween(4000, easing = LinearEasing)), label = "r",
    )
    val tail = 0.16f   // fraction of a turn the fading tail covers
    BoxWithConstraints(modifier, contentAlignment = Alignment.Center) {
        val box = minOf(maxWidth, maxHeight)
        Canvas(Modifier.size(box)) {
            val c = center
            val r = size.minDimension / 2
            for (i in 1..4) drawCircle(p.ink.copy(alpha = 0.10f), r * i / 4, c, style = Stroke(1.dp.toPx()))
            drawLine(p.ink.copy(alpha = 0.08f), Offset(c.x, 0f), Offset(c.x, size.height))
            drawLine(p.ink.copy(alpha = 0.08f), Offset(0f, c.y), Offset(size.width, c.y))
            // Thin sweep: a short fading tail that ends in a bright leading edge, then rotates.
            rotate(rot, c) {
                drawCircle(
                    Brush.sweepGradient(
                        colorStops = arrayOf(
                            0f to ActionBlue.copy(alpha = 0f), (1 - tail) to ActionBlue.copy(alpha = 0f),
                            0.999f to ActionBlue.copy(alpha = 0.45f), 1f to ActionBlue.copy(alpha = 0f)),
                        center = c),
                    r, c)
                drawLine(ActionBlue, c, Offset(c.x + r, c.y), strokeWidth = 2.dp.toPx())
            }
            drawCircle(ActionBlue.copy(alpha = 0.25f), 12.dp.toPx(), c)
            drawCircle(Color.White, 8.dp.toPx(), c)
            drawCircle(ActionBlue, 6.dp.toPx(), c)
        }
        peers.forEach { peer ->
            val rr = radiusFor(peer) * (box.value / 2)
            val a = angleFor(peer)
            Column(Modifier.offset(x = (cos(a) * rr).dp, y = (sin(a) * rr).dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(Modifier.size(13.dp).background(if (peer.hops == 1) ActionBlue else Color.White, CircleShape)
                    .border(2.dp, ActionBlue, CircleShape))
                Text(peer.name, color = p.ink, fontSize = 11.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}

// ───────────────────────── Chats ─────────────────────────

@Composable
fun ChatsScreen(store: ChatStore, onOpen: (String) -> Unit) {
    val p = LocalPalette.current
    LazyColumn(Modifier.fillMaxSize().statusBarsPadding(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { PageTitle("Chats") }
        if (store.conversations.isEmpty()) item {
            Card {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.Forum, null, tint = ActionBlue, modifier = Modifier.size(36.dp))
                    Text("No conversations yet", color = p.ink, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                    Text("Open Nearby and tap someone to say hi.", color = p.inkSecondary, fontSize = 13.sp)
                }
            }
        }
        items(store.conversations, key = { it.id }) { c ->
            Card(Modifier.clickable { onOpen(c.id) }, padding = 12.dp) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Avatar(c.peer.name, 52.dp, online = c.peer.hops == 1)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row {
                            Text(c.peer.name, color = p.ink, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                            c.messages.lastOrNull()?.let { Text(timeOf(it.timeMs), color = p.inkSecondary, fontSize = 12.sp) }
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(c.messages.lastOrNull()?.text ?: "", color = p.inkSecondary, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            if (c.unread > 0) Text("${c.unread}", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                                modifier = Modifier.background(ActionBlue, CircleShape).padding(horizontal = 8.dp, vertical = 3.dp))
                        }
                    }
                }
            }
        }
    }
}

// ───────────────────────── Thread ─────────────────────────

@Composable
fun ThreadScreen(store: ChatStore, conversationId: String, peer: Peer, onBack: () -> Unit) {
    val p = LocalPalette.current
    val convo = store.conversations.firstOrNull { it.id == conversationId }
    val messages = convo?.messages ?: emptyList()
    var draft by remember { mutableStateOf("") }
    val listState = rememberLazyListState()
    LaunchedEffect(conversationId) { store.ensureConversation(peer); store.markRead(conversationId) }
    LaunchedEffect(messages.size) {
        store.markRead(conversationId)
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.size)
    }
    Column(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().glass(0.dp).padding(horizontal = 8.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.ArrowBack, "Back", tint = p.link, modifier = Modifier.clickable(onClick = onBack).padding(8.dp))
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(peer.name, color = p.ink, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                Text(if (peer.hops == 1) "Direct link" else "${peer.hops} hops", color = p.secure, fontSize = 11.sp)
            }
            Spacer(Modifier.width(40.dp))
        }
        LazyColumn(Modifier.weight(1f), state = listState, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            item {
                Box(Modifier.fillMaxWidth().padding(vertical = 10.dp), contentAlignment = Alignment.Center) {
                    SkyPill { Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Filled.Lock, null, tint = Color.White, modifier = Modifier.size(13.dp))
                        Text("Offline · end-to-end encryption planned", color = Color.White, fontSize = 12.sp)
                    } }
                }
            }
            items(messages, key = { it.id }) { Bubble(it) }
        }
        Row(Modifier.fillMaxWidth().glass(0.dp).navigationBarsPadding().padding(12.dp, 8.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.weight(1f).glass(16.dp).padding(horizontal = 16.dp, vertical = 12.dp)) {
                if (draft.isEmpty()) Text("Message", color = p.inkSecondary, fontSize = 16.sp)
                BasicTextField(draft, { draft = it }, Modifier.fillMaxWidth(), textStyle = TextStyle(color = p.ink, fontSize = 16.sp), cursorBrush = SolidColor(ActionBlue), maxLines = 5)
            }
            val canSend = draft.isNotBlank()
            Box(Modifier.size(46.dp).background(if (canSend) ActionBlue else ActionBlue.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
                .clickable(enabled = canSend) { store.send(draft.trim(), conversationId); draft = "" }, contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.ArrowUpward, "Send", tint = Color.White)
            }
        }
    }
}

@Composable
private fun Bubble(m: Message) {
    val p = LocalPalette.current
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (m.mine) Arrangement.End else Arrangement.Start) {
        Column(horizontalAlignment = if (m.mine) Alignment.End else Alignment.Start, modifier = Modifier.widthIn(max = 300.dp)) {
            Text(m.text, color = if (m.mine) Color.White else p.ink, fontSize = 16.sp,
                modifier = (if (m.mine) Modifier.background(ActionBlue, RoundedCornerShape(20.dp)) else Modifier.glass(20.dp)).padding(horizontal = 14.dp, vertical = 10.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(top = 3.dp)) {
                Text(timeOf(m.timeMs), color = Color.White.copy(alpha = 0.85f), fontSize = 11.sp)
                if (m.mine) Icon(when (m.state) {
                    Delivery.Sending -> Icons.Filled.Schedule
                    Delivery.Sent -> Icons.Filled.Check
                    Delivery.Relayed -> Icons.Filled.CallSplit
                    Delivery.Delivered -> Icons.Filled.CheckCircle
                    Delivery.Failed -> Icons.Filled.Warning
                }, null, tint = Color.White.copy(alpha = 0.85f), modifier = Modifier.size(12.dp))
            }
        }
    }
}

// ───────────────────────── You ─────────────────────────

@Composable
fun IdentityScreen(store: ChatStore) {
    val p = LocalPalette.current
    LazyColumn(Modifier.fillMaxSize().statusBarsPadding(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { PageTitle("You") }
        item {
            Card {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Avatar(store.nickname, 88.dp)
                    BasicTextField(store.nickname, { store.updateNickname(it) }, singleLine = true,
                        textStyle = TextStyle(color = p.ink, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center),
                        cursorBrush = SolidColor(ActionBlue), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { store.applyNickname() }), modifier = Modifier.fillMaxWidth())
                    StatusPill("No account · no phone number")
                }
            }
        }
        item {
            Card {
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Filled.Key, null, tint = p.ink, modifier = Modifier.size(16.dp))
                        Text("Your fingerprint", color = p.ink, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Text("A3F1 9C02 7BD4 E58A\n11C0 4F6E 92AB 3D77", color = p.link, fontFamily = FontFamily.Monospace, fontSize = 15.sp)
                    Text("Compare this in person to verify a contact. Placeholder until keys are generated on device.", color = p.inkSecondary, fontSize = 13.sp)
                }
            }
        }
        item {
            SkyPill(Modifier.fillMaxWidth()) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Filled.Construction, null, tint = Color.White, modifier = Modifier.size(16.dp))
                    Text("Project status", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                }
                Spacer(Modifier.height(6.dp))
                Text("Early development. Shows simulated peers on emulators. Not security audited. Bitchat compatibility unverified. GPL-3.0.", color = Color.White.copy(alpha = 0.85f), fontSize = 13.sp)
            }
        }
    }
}
