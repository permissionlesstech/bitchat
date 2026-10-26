package app.nearsend.chat

import androidx.annotation.StringRes
import androidx.appcompat.app.AppCompatDelegate
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
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.os.LocaleListCompat
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

private fun timeOf(ms: Long): String = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ms))

/** Each language is listed in its own language so people can find it whatever the app is currently showing. */
val LANGUAGES = listOf(
    "en" to "English", "sv" to "Svenska", "es" to "Español", "fr" to "Français", "de" to "Deutsch", "pt" to "Português",
    "it" to "Italiano", "ar" to "العربية", "tr" to "Türkçe", "ru" to "Русский", "zh-CN" to "简体中文", "ja" to "日本語",
)

// ───────────────────────── Onboarding ─────────────────────────

private class OnboardPage(val icon: ImageVector, @StringRes val title: Int, @StringRes val body: Int)

@Composable
fun OnboardingScreen(onDone: () -> Unit) {
    val pages = remember {
        listOf(
            OnboardPage(Icons.Filled.Sensors, R.string.ob1_title, R.string.ob1_body),
            OnboardPage(Icons.Filled.Hub, R.string.ob2_title, R.string.ob2_body),
            OnboardPage(Icons.Filled.Lock, R.string.ob3_title, R.string.ob3_body),
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
            Text(stringResource(R.string.early_dev), color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium,
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
                Text(upper(stringResource(pg.title)), fontFamily = Anton, fontSize = 40.sp, color = Color.White, textAlign = TextAlign.Center, lineHeight = 44.sp)
                Spacer(Modifier.height(16.dp))
                SkyPill { Text(stringResource(pg.body), color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center) }
            }
        }
        Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalArrangement = Arrangement.Center) {
            for (i in pages.indices) Box(Modifier.padding(4.dp).size(8.dp).background(Color.White.copy(alpha = if (i == pager.currentPage) 1f else 0.4f), CircleShape))
        }
        val last = pager.currentPage == pages.size - 1
        PrimaryButton(stringResource(if (last) R.string.ob_allow else R.string.ob_continue), Modifier.padding(horizontal = 24.dp)) {
            if (last) onDone() else scope.launch { pager.animateScrollToPage(pager.currentPage + 1) }
        }
    }
}

// ───────────────────────── Nearby + radar ─────────────────────────

@Composable
fun NearbyScreen(store: ChatStore, onOpenChat: (Peer) -> Unit) {
    val p = LocalPalette.current
    val ctx = LocalContext.current
    val live = !store.simulated
    val statusOk = store.meshActive && (store.simulated || store.bluetoothState == "ready")
    val needsSettings = live && store.bluetoothState in listOf("off", "unauthorized")
    @StringRes val statusText = when {
        !store.meshActive -> R.string.st_paused
        store.simulated -> R.string.st_demo
        else -> when (store.bluetoothState) {
            "ready" -> R.string.st_live
            "off" -> R.string.st_off
            "unauthorized" -> R.string.st_denied
            "unsupported" -> R.string.st_unsupported
            else -> R.string.st_starting
        }
    }
    val subtitle: Int? = when {
        live && store.bluetoothState == "unauthorized" -> R.string.sub_denied
        live && store.bluetoothState == "off" -> R.string.sub_off
        live && store.peers.isEmpty() -> R.string.sub_empty
        else -> null
    }
    val switchLabel = stringResource(R.string.mesh_switch)
    LazyColumn(Modifier.fillMaxSize().statusBarsPadding(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { PageTitle(R.string.tab_nearby) }
        item {
            Card {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        StatusPill(stringResource(statusText), if (statusOk) p.secure else p.inkSecondary)
                        Text(if (store.peers.size == 1) stringResource(R.string.one_person) else stringResource(R.string.n_people, store.peers.size),
                            color = p.ink, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                        Text(if (subtitle != null) stringResource(subtitle) else stringResource(R.string.n_relay, store.relayedCount), color = p.inkSecondary, fontSize = 13.sp)
                        if (needsSettings) Text(stringResource(R.string.open_settings), color = p.link, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.clickable { if (store.bluetoothState == "off") SystemSettings.openBluetooth(ctx) else SystemSettings.openAppSettings(ctx) })
                    }
                    Switch(store.meshActive, { store.setMesh(it) }, Modifier.semantics { contentDescription = switchLabel },
                        colors = SwitchDefaults.colors(checkedTrackColor = ActionBlue, checkedThumbColor = Color.White))
                }
            }
        }
        item { Card(padding = 12.dp) { Radar(store.peers, Modifier.fillMaxWidth().height(320.dp)) } }
        items(store.peers, key = { it.id }) { peer ->
            Card(Modifier.clickable { onOpenChat(peer) }, padding = 12.dp) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Avatar(peer.name, online = true)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(peer.name, color = p.ink, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                            if (peer.verified) Icon(Icons.Filled.Verified, stringResource(R.string.verified), tint = ActionBlue, modifier = Modifier.size(15.dp))
                        }
                        Text(if (peer.hops == 1) stringResource(R.string.direct_dbm, peer.rssi) else stringResource(R.string.n_hops_relay, peer.hops),
                            color = p.inkSecondary, fontSize = 13.sp)
                    }
                    SignalBars(peer.rssi)
                }
            }
        }
    }
}

private fun radiusFor(p: Peer) = ((-40 - p.rssi) / 55f).coerceIn(0.18f, 1f)
/** Golden-angle spread from the id so people don't bunch together and stay put between updates. */
private fun angleFor(p: Peer): Float {
    var h = 0
    for (c in p.id) h = (h * 31 + c.code) and 0xFFFFFF
    return ((h * 137.508) % 360.0).toFloat() * Math.PI.toFloat() / 180f
}

@Composable
fun Radar(peers: List<Peer>, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val rot by rememberInfiniteTransition(label = "sweep").animateFloat(
        0f, 360f, infiniteRepeatable(tween(4000, easing = LinearEasing)), label = "r",
    )
    val tail = 0.16f   // fraction of a turn the fading tail covers
    val desc = stringResource(R.string.radar) + ": " + if (peers.size == 1) stringResource(R.string.one_person) else stringResource(R.string.n_people, peers.size)
    BoxWithConstraints(modifier.semantics { contentDescription = desc }, contentAlignment = Alignment.Center) {
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
                Box(Modifier.size(13.dp).background(if (peer.hops == 1) ActionBlue else Color.White, CircleShape).border(2.dp, ActionBlue, CircleShape))
                Text(peer.name, color = p.ink, fontSize = 11.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}

// ───────────────────────── Chats ─────────────────────────

@Composable
fun ChatsScreen(store: ChatStore, onOpen: (String) -> Unit) {
    val p = LocalPalette.current
    val sorted = store.conversations.sortedWith(compareBy<Conversation> { it.id != PUBLIC_CHANNEL_ID }
        .thenByDescending { it.messages.lastOrNull()?.timeMs ?: 0L })
    LazyColumn(Modifier.fillMaxSize().statusBarsPadding(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { PageTitle(R.string.tab_chats) }
        if (store.conversations.size <= 1) item {
            Card {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.Forum, null, tint = ActionBlue, modifier = Modifier.size(30.dp))
                    Text(stringResource(R.string.no_chats), color = p.ink, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                    Text(stringResource(R.string.no_chats_hint), color = p.inkSecondary, fontSize = 13.sp, textAlign = TextAlign.Center)
                }
            }
        }
        items(sorted, key = { it.id }) { c ->
            val isPublic = c.id == PUBLIC_CHANNEL_ID
            Card(Modifier.clickable { onOpen(c.id) }, padding = 12.dp) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Avatar(if (isPublic) "#" else c.peer.name, 52.dp, online = !isPublic && c.peer.hops == 1)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row {
                            Text(if (isPublic) stringResource(R.string.nearby_channel) else c.peer.name, color = p.ink, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                            c.messages.lastOrNull()?.let { Text(timeOf(it.timeMs), color = p.inkSecondary, fontSize = 12.sp) }
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            val last = c.messages.lastOrNull()
                            Text(when {
                                last == null -> if (isPublic) stringResource(R.string.public_hint) else ""
                                last.sender != null -> "${last.sender}: ${last.text}"
                                else -> last.text
                            }, color = p.inkSecondary, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
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
    val isPublic = conversationId == PUBLIC_CHANNEL_ID
    val messages = store.conversations.firstOrNull { it.id == conversationId }?.messages ?: emptyList()
    val livePeer = store.peers.firstOrNull { it.id == conversationId } ?: peer
    val online = isPublic || store.peers.any { it.id == conversationId }
    val encrypted = store.simulated || livePeer.fingerprint.isNotEmpty()
    var draft by remember { mutableStateOf("") }
    var showInfo by remember { mutableStateOf(false) }
    val listState = rememberLazyListState()
    DisposableEffect(conversationId) {
        store.activeConversation = conversationId
        store.ensureConversation(peer); store.markRead(conversationId)
        onDispose { if (store.activeConversation == conversationId) store.activeConversation = null }
    }
    LaunchedEffect(messages.size) {
        store.markRead(conversationId)
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.size)
    }
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
            Row(Modifier.fillMaxWidth().glass(0.dp).padding(horizontal = 8.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = p.link, modifier = Modifier.clickable(onClick = onBack).padding(8.dp))
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(if (isPublic) stringResource(R.string.nearby_channel) else livePeer.name, color = p.ink, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                    Text(when {
                        isPublic -> stringResource(R.string.public_channel)
                        !online -> stringResource(R.string.out_of_range)
                        livePeer.hops == 1 -> stringResource(R.string.direct_link)
                        else -> stringResource(R.string.n_hops, livePeer.hops)
                    }, color = if (online) p.secure else p.inkSecondary, fontSize = 11.sp)
                }
                if (isPublic) Spacer(Modifier.width(40.dp))
                else Icon(Icons.Filled.Info, stringResource(R.string.contact_info), tint = p.link, modifier = Modifier.clickable { showInfo = true }.padding(8.dp))
            }
            LazyColumn(Modifier.weight(1f), state = listState, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                item {
                    Box(Modifier.fillMaxWidth().padding(vertical = 10.dp), contentAlignment = Alignment.Center) {
                        SkyPill { Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(if (isPublic) Icons.Filled.Campaign else Icons.Filled.Lock, null, tint = Color.White, modifier = Modifier.size(13.dp))
                            Text(stringResource(if (isPublic) R.string.public_hint else if (encrypted) R.string.e2e else R.string.waiting_keys), color = Color.White, fontSize = 12.sp)
                        } }
                    }
                }
                items(messages, key = { it.id }) { m -> Bubble(m, isPublic) { store.retry(m.id, conversationId) } }
            }
            Row(Modifier.fillMaxWidth().glass(0.dp).navigationBarsPadding().padding(12.dp, 8.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.weight(1f).glass(16.dp).padding(horizontal = 16.dp, vertical = 12.dp)) {
                    if (draft.isEmpty()) Text(stringResource(R.string.message), color = p.inkSecondary, fontSize = 16.sp)
                    BasicTextField(draft, { draft = it }, Modifier.fillMaxWidth(), textStyle = TextStyle(color = p.ink, fontSize = 16.sp), cursorBrush = SolidColor(ActionBlue), maxLines = 5)
                }
                val canSend = draft.isNotBlank()
                Box(Modifier.size(46.dp).background(if (canSend) ActionBlue else ActionBlue.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
                    .clickable(enabled = canSend) { store.send(draft.trim(), conversationId); draft = "" }, contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.ArrowUpward, stringResource(R.string.send), tint = Color.White)
                }
            }
        }
        if (showInfo) PeerInfo(livePeer, store) { showInfo = false }
    }
}

@Composable
private fun Bubble(m: Message, showSender: Boolean, onRetry: () -> Unit) {
    val p = LocalPalette.current
    val stateName = stringResource(when (m.state) {
        Delivery.Sending -> R.string.state_sending; Delivery.Sent -> R.string.state_sent; Delivery.Relayed -> R.string.state_relayed
        Delivery.Delivered -> R.string.state_delivered; Delivery.Failed -> R.string.state_failed
    })
    Row(Modifier.fillMaxWidth().clickable(enabled = m.state == Delivery.Failed, onClick = onRetry), horizontalArrangement = if (m.mine) Arrangement.End else Arrangement.Start) {
        Column(horizontalAlignment = if (m.mine) Alignment.End else Alignment.Start, modifier = Modifier.widthIn(max = 300.dp)) {
            if (showSender && !m.mine && m.sender != null)
                Text(m.sender, color = Color.White.copy(alpha = 0.9f), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 6.dp))
            Text(m.text, color = if (m.mine) Color.White else p.ink, fontSize = 16.sp,
                modifier = (if (m.mine) Modifier.background(ActionBlue, RoundedCornerShape(20.dp)) else Modifier.glass(20.dp)).padding(horizontal = 14.dp, vertical = 10.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(top = 3.dp)) {
                Text(timeOf(m.timeMs), color = Color.White.copy(alpha = 0.85f), fontSize = 11.sp)
                if (!m.mine && m.hops > 1) Text(stringResource(R.string.dot_n_hops, m.hops), color = Color.White.copy(alpha = 0.85f), fontSize = 11.sp)
                if (m.mine) Icon(when (m.state) {
                    Delivery.Sending -> Icons.Filled.Schedule
                    Delivery.Sent -> Icons.Filled.Check
                    Delivery.Relayed -> Icons.Filled.CallSplit
                    Delivery.Delivered -> Icons.Filled.CheckCircle
                    Delivery.Failed -> Icons.Filled.Warning
                }, stateName, tint = Color.White.copy(alpha = 0.85f), modifier = Modifier.size(12.dp))
                if (m.state == Delivery.Failed) Text(stringResource(R.string.tap_retry), color = Color.White.copy(alpha = 0.85f), fontSize = 11.sp)
            }
        }
    }
}

/** Fingerprint comparison: two people read their digits to each other in person to rule out an impostor. */
@Composable
private fun PeerInfo(peer: Peer, store: ChatStore, onClose: () -> Unit) {
    val p = LocalPalette.current
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)).clickable(onClick = onClose), contentAlignment = Alignment.BottomCenter) {
        Column(Modifier.fillMaxWidth().glass(24.dp).clickable(enabled = false) {}.navigationBarsPadding().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Avatar(peer.name, 72.dp)
            Text(peer.name, color = p.ink, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Filled.Key, null, tint = p.ink, modifier = Modifier.size(16.dp))
                    Text(stringResource(R.string.their_fp), color = p.ink, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                }
                Text(peer.fingerprint.ifEmpty { "—" }, color = p.link, fontFamily = FontFamily.Monospace, fontSize = 18.sp)
                Text(stringResource(R.string.their_fp_hint), color = p.inkSecondary, fontSize = 13.sp)
            }
            PrimaryButton(stringResource(if (peer.verified) R.string.remove_verif else R.string.mark_verif)) { store.toggleVerified(peer); onClose() }
            Text(stringResource(R.string.close), color = p.link, fontSize = 15.sp, modifier = Modifier.clickable(onClick = onClose).padding(8.dp))
        }
    }
}

// ───────────────────────── You ─────────────────────────

@Composable
fun IdentityScreen(store: ChatStore) {
    val p = LocalPalette.current
    var confirmWipe by remember { mutableStateOf(false) }
    var langMenu by remember { mutableStateOf(false) }
    var taps by remember { mutableIntStateOf(0) }
    var lastTap by remember { mutableLongStateOf(0L) }
    val current = AppCompatDelegate.getApplicationLocales().toLanguageTags()
    val currentName = LANGUAGES.firstOrNull { current.isNotEmpty() && current.startsWith(it.first.substringBefore('-')) }?.second
    LazyColumn(Modifier.fillMaxSize().statusBarsPadding(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item {
            PageTitle(R.string.tab_you, Modifier.clickable {   // panic: triple-tap
                val now = System.currentTimeMillis()
                taps = if (now - lastTap < 700) taps + 1 else 1
                lastTap = now
                if (taps >= 3) { taps = 0; confirmWipe = true }
            })
        }
        item {
            Card {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Avatar(store.nickname, 88.dp)
                    BasicTextField(store.nickname, { store.updateNickname(it) }, singleLine = true,
                        textStyle = TextStyle(color = p.ink, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center),
                        cursorBrush = SolidColor(ActionBlue), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { store.applyNickname() }), modifier = Modifier.fillMaxWidth())
                    StatusPill(stringResource(R.string.no_account))
                }
            }
        }
        item {
            Card {
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Filled.Key, null, tint = p.ink, modifier = Modifier.size(16.dp))
                        Text(stringResource(R.string.your_fp), color = p.ink, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Text(store.myFingerprint.ifEmpty { "—" }, color = p.link, fontFamily = FontFamily.Monospace, fontSize = 15.sp)
                    Text(stringResource(R.string.your_fp_hint), color = p.inkSecondary, fontSize = 13.sp)
                }
            }
        }
        item {
            Card {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Language, null, tint = p.ink, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.language), color = p.ink, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    Box {
                        Text(currentName ?: stringResource(R.string.language_system), color = p.link, fontSize = 15.sp, modifier = Modifier.clickable { langMenu = true }.padding(8.dp))
                        DropdownMenu(langMenu, { langMenu = false }) {
                            DropdownMenuItem({ Text(stringResource(R.string.language_system)) }, { langMenu = false; AppCompatDelegate.setApplicationLocales(LocaleListCompat.getEmptyLocaleList()) })
                            LANGUAGES.forEach { (tag, name) ->
                                DropdownMenuItem({ Text(name) }, { langMenu = false; AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags(tag)) })
                            }
                        }
                    }
                }
            }
        }
        item {
            Box(Modifier.fillMaxWidth().glass(12.dp).clickable { confirmWipe = true }.padding(vertical = 14.dp), contentAlignment = Alignment.Center) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Filled.Delete, null, tint = Color(0xFFD93025), modifier = Modifier.size(16.dp))
                    Text(stringResource(R.string.erase), color = Color(0xFFD93025), fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
        item {
            SkyPill(Modifier.fillMaxWidth()) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Filled.Construction, null, tint = Color.White, modifier = Modifier.size(16.dp))
                    Text(stringResource(R.string.project_status), color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                }
                Spacer(Modifier.height(6.dp))
                Text(stringResource(R.string.project_status_body), color = Color.White.copy(alpha = 0.85f), fontSize = 13.sp)
            }
        }
    }
    if (confirmWipe) AlertDialog(
        onDismissRequest = { confirmWipe = false },
        title = { Text(stringResource(R.string.erase_confirm)) },
        text = { Text(stringResource(R.string.erase_confirm_body)) },
        confirmButton = { TextButton({ confirmWipe = false; store.wipeAll() }) { Text(stringResource(R.string.erase), color = Color(0xFFD93025)) } },
        dismissButton = { TextButton({ confirmWipe = false }) { Text(stringResource(R.string.cancel)) } },
    )
}
