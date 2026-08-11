package mov.unblocked.resonance.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

val Navy = Color(0xFF090A0F)
val DeepNavy = Color(0xFF020305)
val NavySurface = Color(0xFF0B0C11)
val RaisedSurface = Color(0xFF12131A)
val Accent = Color(0xFF7547FF)
val Violet = Color(0xFF6540F5)
val ElectricBlue = Color(0xFF9B82FF)
val SuccessGreen = Color(0xFF35D477)

private val ResonanceColors = darkColorScheme(
    primary = Accent,
    secondary = Violet,
    tertiary = ElectricBlue,
    background = DeepNavy,
    surface = NavySurface,
    onPrimary = Color.White,
    onSecondary = Color.White,
    onBackground = Color(0xFFF5F5F7),
    onSurface = Color(0xFFF5F5F7),
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
