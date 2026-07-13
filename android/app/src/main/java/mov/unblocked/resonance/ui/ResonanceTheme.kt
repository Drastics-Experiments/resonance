package mov.unblocked.resonance.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

val Navy = Color(0xFF101229)
val DeepNavy = Color(0xFF07101C)
val NavySurface = Color(0xFF1B1F38)
val Coral = Color(0xFFFF6F68)
val Violet = Color(0xFF6558FF)
val ElectricBlue = Color(0xFF6C9CD8)
val SuccessGreen = Color(0xFF35D477)

private val ResonanceColors = darkColorScheme(
    primary = Coral,
    secondary = Violet,
    tertiary = ElectricBlue,
    background = DeepNavy,
    surface = NavySurface,
    onPrimary = Color.White,
    onSecondary = Color.White,
    onBackground = Color(0xFFF5F4FA),
    onSurface = Color(0xFFF5F4FA),
    error = Color(0xFFFF555F),
)

@Composable
fun ResonanceTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = ResonanceColors,
        typography = MaterialTheme.typography.copy(
            headlineLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Bold, fontSize = 36.sp),
            titleLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Bold, fontSize = 24.sp),
            titleMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 17.sp),
        ),
        content = content,
    )
}
