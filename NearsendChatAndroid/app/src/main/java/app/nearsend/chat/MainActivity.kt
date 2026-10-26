package app.nearsend.chat

import android.Manifest
import android.graphics.Color as AndroidColor
import android.os.Build
import android.os.Bundle
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.os.LocaleListCompat

class MainActivity : AppCompatActivity() {
    private val store: ChatStore by viewModels()

    private val permLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { store.startIfNeeded() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Demo/screenshot extra: force a language, e.g. `--es lang ar`. Normal use goes through the You tab or system settings.
        intent.getStringExtra("lang")?.let { tag ->
            if (AppCompatDelegate.getApplicationLocales().toLanguageTags() != tag) {
                AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags(tag))
            }
        }
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
        )
        val prefs = getSharedPreferences("nearsend", MODE_PRIVATE)
        // Launch extras let screenshots / demos jump straight to a screen.
        val onboarded = if (intent.hasExtra("onboarded")) intent.getBooleanExtra("onboarded", false) else prefs.getBoolean("onboarded", false)
        val tab = intent.getIntExtra("tab", 0)
        val thread = intent.getStringExtra("thread")
        setContent {
            NearsendApp(store, onboarded, tab, thread) {
                prefs.edit().putBoolean("onboarded", true).apply()
                requestPermissions()
            }
        }
    }

    override fun onStart() { super.onStart(); Notifier.foreground = true }
    override fun onStop() { super.onStop(); Notifier.foreground = false }

    override fun onResume() {
        super.onResume()
        if (getSharedPreferences("nearsend", MODE_PRIVATE).getBoolean("onboarded", false)) store.startIfNeeded()
    }

    private fun requestPermissions() {
        if (store.simulated) { store.startIfNeeded(); return }
        val needed = store.blePermissions().toMutableList()
        if (Build.VERSION.SDK_INT >= 33) needed += Manifest.permission.POST_NOTIFICATIONS
        if (store.hasBlePermissions() && Notifier.hasPermission(this)) store.startIfNeeded()
        else permLauncher.launch(needed.toTypedArray())
    }
}

@Composable
fun NearsendApp(store: ChatStore, startOnboarded: Boolean, startTab: Int, startThread: String?, onOnboardingDone: () -> Unit) {
    val night = isSystemInDarkTheme()
    var onboarded by remember { mutableStateOf(startOnboarded) }
    var tab by remember { mutableIntStateOf(startTab) }
    var thread by remember { mutableStateOf(startThread) }
    var threadPeer by remember { mutableStateOf<Peer?>(null) }
    val openPeer = threadPeer ?: thread?.let { id -> store.conversations.firstOrNull { it.id == id }?.peer }
    LaunchedEffect(store.wipeCount) { if (store.wipeCount > 0) { onboarded = false; thread = null; tab = 0 } }

    CompositionLocalProvider(LocalPalette provides if (night) NightPalette else DayPalette) {
        Box(Modifier.fillMaxSize()) {
            SkyBackground()
            if (!onboarded) {
                OnboardingScreen { onboarded = true; onOnboardingDone() }
            } else if (thread != null && openPeer != null) {
                BackHandler { thread = null; threadPeer = null }
                ThreadScreen(store, thread!!, openPeer) { thread = null; threadPeer = null }
            } else {
                Column(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f)) {
                        when (tab) {
                            0 -> NearbyScreen(store) { peer -> store.ensureConversation(peer); threadPeer = peer; thread = peer.id }
                            1 -> ChatsScreen(store) { id -> threadPeer = null; thread = id }
                            else -> IdentityScreen(store)
                        }
                    }
                    TabBar(tab, store.unreadTotal) { tab = it }
                }
            }
        }
    }
}

@Composable
private fun TabBar(selected: Int, unread: Int, onSelect: (Int) -> Unit) {
    val p = LocalPalette.current
    val items: List<Pair<Int, ImageVector>> = listOf(R.string.tab_nearby to Icons.Filled.Sensors, R.string.tab_chats to Icons.Filled.Chat, R.string.tab_you to Icons.Filled.Person)
    Row(Modifier.fillMaxWidth().glass(0.dp).navigationBarsPadding().padding(vertical = 8.dp)) {
        items.forEachIndexed { i, (labelRes, icon) ->
            val color = if (i == selected) p.link else p.inkSecondary
            val label = stringResource(labelRes)
            Column(Modifier.weight(1f).clickable { onSelect(i) }.padding(vertical = 4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Box {
                    Icon(icon, label, tint = color)
                    if (i == 1 && unread > 0) Text("$unread", color = androidx.compose.ui.graphics.Color.White, fontSize = 10.sp,
                        modifier = Modifier.align(Alignment.TopEnd).offset(10.dp, (-4).dp).background(androidx.compose.ui.graphics.Color(0xFFFF3B30), RoundedCornerShape(50)).padding(horizontal = 5.dp))
                }
                Text(label, color = color, fontSize = 11.sp)
            }
        }
    }
}
