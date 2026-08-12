package mov.unblocked.resonance.ui

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

enum class ResonanceThemeChoice(
    val storageID: String,
    val label: String,
) {
    Midnight("midnight", "Midnight"),
    Ocean("ocean", "Ocean"),
    Forest("forest", "Forest"),
    Sunset("sunset", "Sunset"),
    ;

    companion object {
        fun fromStorageID(value: String?): ResonanceThemeChoice {
            val normalized = value?.trim().orEmpty()
            return entries.firstOrNull { it.storageID.equals(normalized, ignoreCase = true) }
                ?: Midnight
        }
    }
}

@Immutable
internal data class ResonancePalette(
    val background: Color,
    val panel: Color,
    val surface: Color,
    val raised: Color,
    val accent: Color,
    val secondary: Color,
    val tertiary: Color,
    val success: Color = Color(0xFF35D477),
)

private val MidnightPalette = ResonancePalette(
    background = Color(0xFF020305),
    panel = Color(0xFF07080C),
    surface = Color(0xFF0B0C11),
    raised = Color(0xFF12131A),
    accent = Color(0xFF7547FF),
    secondary = Color(0xFF6540F5),
    tertiary = Color(0xFF9B82FF),
)

private val OceanPalette = ResonancePalette(
    background = Color(0xFF02070D),
    panel = Color(0xFF050D14),
    surface = Color(0xFF07121B),
    raised = Color(0xFF0D1D2A),
    accent = Color(0xFF1769C2),
    secondary = Color(0xFF0F5CAA),
    tertiary = Color(0xFF55B8FF),
)

private val ForestPalette = ResonancePalette(
    background = Color(0xFF020805),
    panel = Color(0xFF050D09),
    surface = Color(0xFF07120C),
    raised = Color(0xFF0D1D14),
    accent = Color(0xFF198754),
    secondary = Color(0xFF126B43),
    tertiary = Color(0xFF5FD49A),
)

private val SunsetPalette = ResonancePalette(
    background = Color(0xFF0A0403),
    panel = Color(0xFF100706),
    surface = Color(0xFF150A07),
    raised = Color(0xFF21120E),
    accent = Color(0xFFC45132),
    secondary = Color(0xFFA33A53),
    tertiary = Color(0xFFFF9A62),
)

internal fun paletteForTheme(choice: ResonanceThemeChoice): ResonancePalette = when (choice) {
    ResonanceThemeChoice.Midnight -> MidnightPalette
    ResonanceThemeChoice.Ocean -> OceanPalette
    ResonanceThemeChoice.Forest -> ForestPalette
    ResonanceThemeChoice.Sunset -> SunsetPalette
}

internal val LocalResonancePalette = staticCompositionLocalOf { MidnightPalette }

internal fun colorSchemeForPalette(palette: ResonancePalette): ColorScheme = ColorScheme(
    primary = palette.accent,
    onPrimary = Color.White,
    primaryContainer = palette.raised,
    onPrimaryContainer = palette.tertiary,
    inversePrimary = palette.secondary,
    secondary = palette.secondary,
    onSecondary = Color.White,
    secondaryContainer = palette.raised,
    onSecondaryContainer = palette.tertiary,
    tertiary = palette.tertiary,
    onTertiary = palette.background,
    tertiaryContainer = palette.raised,
    onTertiaryContainer = palette.tertiary,
    background = palette.background,
    onBackground = Color(0xFFF5F5F7),
    surface = palette.surface,
    onSurface = Color(0xFFF5F5F7),
    surfaceVariant = palette.raised,
    onSurfaceVariant = Color(0xFFC8C7CF),
    surfaceTint = palette.accent,
    inverseSurface = Color(0xFFF5F5F7),
    inverseOnSurface = Color(0xFF1B1B20),
    error = Color(0xFFFF555F),
    onError = Color(0xFF210005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    outline = palette.tertiary.copy(alpha = .65f),
    outlineVariant = palette.tertiary.copy(alpha = .28f),
    scrim = Color.Black,
    surfaceBright = palette.raised,
    surfaceDim = palette.background,
    surfaceContainer = palette.surface,
    surfaceContainerHigh = palette.raised,
    surfaceContainerHighest = palette.raised,
    surfaceContainerLow = palette.panel,
    surfaceContainerLowest = palette.background,
    primaryFixed = palette.raised,
    primaryFixedDim = palette.surface,
    onPrimaryFixed = palette.tertiary,
    onPrimaryFixedVariant = Color(0xFFC8C7CF),
    secondaryFixed = palette.raised,
    secondaryFixedDim = palette.surface,
    onSecondaryFixed = palette.tertiary,
    onSecondaryFixedVariant = Color(0xFFC8C7CF),
    tertiaryFixed = palette.raised,
    tertiaryFixedDim = palette.surface,
    onTertiaryFixed = palette.tertiary,
    onTertiaryFixedVariant = Color(0xFFC8C7CF),
)

@Composable
fun ResonanceTheme(
    choice: ResonanceThemeChoice = ResonanceThemeChoice.Midnight,
    content: @Composable () -> Unit,
) {
    val palette = paletteForTheme(choice)
    CompositionLocalProvider(LocalResonancePalette provides palette) {
        MaterialTheme(
            colorScheme = colorSchemeForPalette(palette),
            typography = MaterialTheme.typography.copy(
                headlineLarge = TextStyle(
                    fontFamily = FontFamily.SansSerif,
                    fontWeight = FontWeight.Bold,
                    fontSize = 36.sp,
                ),
                titleLarge = TextStyle(
                    fontFamily = FontFamily.SansSerif,
                    fontWeight = FontWeight.Bold,
                    fontSize = 24.sp,
                ),
                titleMedium = TextStyle(
                    fontFamily = FontFamily.SansSerif,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 17.sp,
                ),
            ),
            content = content,
        )
    }
}
