package app.nearsend.chat

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.animation.core.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.sin

// Design tokens from nearsend.app ("The Open Sky"): frosted glass over a day/night sky, one action blue, navy ink.
val ActionBlue = Color(0xFF2F6FE0)
val ActionBlueDeep = Color(0xFF2459C0)
val BrandBlue = Color(0xFF3F7FE8)
val NightBlue = Color(0xFFB7D2FF)
val SkyPillColor = Color(0xFF0E2855).copy(alpha = 0.65f)
val PairedGreen = Color(0xFF1F7A4D)

val Anton = FontFamily(Font(R.font.anton_regular))

class Palette(
    val ink: Color, val inkSecondary: Color, val link: Color, val secure: Color,
    val glassFill: Color, val glassEdge: Color, val glassShadow: Color, val night: Boolean,
)

val DayPalette = Palette(
    ink = Color(0xFF1B2A4A), inkSecondary = Color(0xFF1B2A4A).copy(alpha = 0.62f), link = ActionBlueDeep,
    secure = Color(0xFF0F6B3F), glassFill = Color.White.copy(alpha = 0.84f), glassEdge = Color.White.copy(alpha = 0.95f),
    glassShadow = Color(0xFF143C78).copy(alpha = 0.20f), night = false,
)
val NightPalette = Palette(
    ink = Color(0xFFEAF2FF), inkSecondary = Color(0xFFEAF2FF).copy(alpha = 0.62f), link = NightBlue,
    secure = Color(0xFF6EE7B7), glassFill = Color(0xFF0C1A36).copy(alpha = 0.74), glassEdge = Color.White.copy(alpha = 0.14f),
    glassShadow = Color.Black.copy(alpha = 0.35f), night = true,
)
val LocalPalette = staticCompositionLocalOf { DayPalette }

private fun frac(v: Double) = v - floor(v)

@Composable
fun SkyBackground(modifier: Modifier = Modifier.fillMaxSize()) {
    val p = LocalPalette.current
    val drift by rememberInfiniteTransition(label = "drift").animateFloat(
        0f, 1f, infiniteRepeatable(tween(28000, easing = LinearEasing), RepeatMode.Reverse), label = "d",
    )
    Canvas(modifier) {
        if (p.night) {
            drawRect(Brush.verticalGradient(listOf(Color(0xFF040B1F), Color(0xFF0A1C47), Color(0xFF2B4A86))))
            for (i in 0 until 80) {
                val x = (frac(sin(i * 12.9898) * 43758.5453) * size.width).toFloat()
                val y = (frac(sin(i * 78.233) * 12543.123) * size.height * 0.8).toFloat()
                val r = (0.6 + frac(sin(i * 3.7) * 9999) * 1.2).toFloat()
                drawCircle(Color.White.copy(alpha = (0.35 + frac(sin(i.toDouble()) * 777) * 0.5).toFloat()), r.dp.toPx(), Offset(x, y))
            }
        } else {
            drawRect(Brush.verticalGradient(
                0f to Color(0xFF356CB5), 0.45f to Color(0xFF6D9BD6), 0.8f to Color(0xFFA9C4E6), 1f to Color(0xFFECD2B0)))
            cloud(size.width * (0.25f + 0.1f * drift), size.height * 0.18f, size.width * 0.9f, size.width * 0.22f)
            cloud(size.width * (0.75f - 0.1f * drift), size.height * 0.46f, size.width * 1.1f, size.width * 0.28f)
            cloud(size.width * (0.35f + 0.1f * drift), size.height * 0.78f, size.width * 0.85f, size.width * 0.2f)
        }
    }
}

private fun DrawScope.cloud(cx: Float, cy: Float, w: Float, h: Float) {
    val c = Offset(cx, cy)
    scale(1f, h / w, pivot = c) {
        drawCircle(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.38f), Color.White.copy(alpha = 0f)), center = c, radius = w / 2), w / 2, c)
    }
}

fun Modifier.glass(radius: Dp = 24.dp): Modifier = composed {
    val p = LocalPalette.current
    val shape = RoundedCornerShape(radius)
    this.shadow(8.dp, shape, ambientColor = p.glassShadow, spotColor = p.glassShadow)
        .background(p.glassFill, shape).border(1.dp, p.glassEdge, shape)
}

@Composable
fun Card(modifier: Modifier = Modifier, padding: Dp = 16.dp, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().glass().padding(padding), content = content)
}

/** Page titles sit straight on the sky in the poster face. */
@Composable
fun PageTitle(text: String) {
    Text(text.uppercase(), fontFamily = Anton, fontSize = 40.sp, color = Color.White, modifier = Modifier.fillMaxWidth())
}

/** Text that must read directly on the sky goes on the dark-blue pill. */
@Composable
fun SkyPill(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.background(SkyPillColor, RoundedCornerShape(24.dp)).padding(horizontal = 20.dp, vertical = 12.dp), content = content)
}

@Composable
fun PrimaryButton(title: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier.fillMaxWidth().height(50.dp)
            .background(Brush.verticalGradient(listOf(ActionBlue, ActionBlueDeep)), RoundedCornerShape(12.dp))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(title, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp) }
}

@Composable
fun Avatar(name: String, size: Dp = 48.dp, online: Boolean = false) {
    val shade = (abs(name.hashCode()) % 5) / 10f
    Box(Modifier.size(size)) {
        Box(
            Modifier.size(size).background(Brush.verticalGradient(listOf(BrandBlue.copy(alpha = 1f - shade * 0.3f), ActionBlueDeep)), CircleShape),
            contentAlignment = Alignment.Center,
        ) { Text(name.take(1).uppercase(), color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = (size.value * 0.4f).sp) }
        if (online) Box(Modifier.size(size * 0.26f).align(Alignment.BottomEnd).background(PairedGreen, CircleShape).border(2.dp, Color.White, CircleShape))
    }
}

/** Green is reserved for "connected" and "secure". */
@Composable
fun StatusPill(text: String, color: Color = LocalPalette.current.secure) {
    Row(
        Modifier.background(color.copy(alpha = 0.12f), CircleShape).padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(6.dp).background(color, CircleShape))
        Spacer(Modifier.width(6.dp))
        Text(text, color = color, fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
fun SignalBars(rssi: Int) {
    val p = LocalPalette.current
    val level = if (rssi > -55) 4 else if (rssi > -70) 3 else if (rssi > -82) 2 else 1
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        for (i in 1..4) Box(Modifier.width(4.dp).height((4 + i * 4).dp)
            .background(if (i <= level) ActionBlue else p.inkSecondary.copy(alpha = 0.3f), RoundedCornerShape(1.5.dp)))
    }
}

val BodyStyle = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Start)
