package mov.unblocked.resonance.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ResonanceThemeTest {
    @Test
    fun themeChoicesHaveStableUniqueStorageIDsAndLabels() {
        assertEquals(
            listOf("midnight", "ocean", "forest", "sunset"),
            ResonanceThemeChoice.entries.map(ResonanceThemeChoice::storageID),
        )
        assertEquals(
            listOf("Midnight", "Ocean", "Forest", "Sunset"),
            ResonanceThemeChoice.entries.map(ResonanceThemeChoice::label),
        )
        assertEquals(
            ResonanceThemeChoice.entries.size,
            ResonanceThemeChoice.entries.map(ResonanceThemeChoice::storageID).toSet().size,
        )
    }

    @Test
    fun storedThemeParsingIsTolerantAndFallsBackToMidnight() {
        assertEquals(ResonanceThemeChoice.Ocean, ResonanceThemeChoice.fromStorageID("  OCEAN "))
        assertEquals(ResonanceThemeChoice.Midnight, ResonanceThemeChoice.fromStorageID(null))
        assertEquals(ResonanceThemeChoice.Midnight, ResonanceThemeChoice.fromStorageID(""))
        assertEquals(ResonanceThemeChoice.Midnight, ResonanceThemeChoice.fromStorageID("future-theme"))
    }

    @Test
    fun palettesMatchTheSharedThemeContract() {
        assertPalette(
            choice = ResonanceThemeChoice.Midnight,
            background = 0xFF020305,
            panel = 0xFF07080C,
            surface = 0xFF0B0C11,
            raised = 0xFF12131A,
            accent = 0xFF7547FF,
            secondary = 0xFF6540F5,
            tertiary = 0xFF9B82FF,
            artworkStops = listOf(0xFF6540F5, 0xFF874BFF, 0xFFB079FF),
        )
        assertPalette(
            choice = ResonanceThemeChoice.Ocean,
            background = 0xFF02070D,
            panel = 0xFF050D14,
            surface = 0xFF07121B,
            raised = 0xFF0D1D2A,
            accent = 0xFF1769C2,
            secondary = 0xFF0F5CAA,
            tertiary = 0xFF55B8FF,
            artworkStops = listOf(0xFF0F5CAA, 0xFF218BD6, 0xFF62C3FF),
        )
        assertPalette(
            choice = ResonanceThemeChoice.Forest,
            background = 0xFF020805,
            panel = 0xFF050D09,
            surface = 0xFF07120C,
            raised = 0xFF0D1D14,
            accent = 0xFF198754,
            secondary = 0xFF126B43,
            tertiary = 0xFF5FD49A,
            artworkStops = listOf(0xFF126B43, 0xFF219C64, 0xFF69D89E),
        )
        assertPalette(
            choice = ResonanceThemeChoice.Sunset,
            background = 0xFF0A0403,
            panel = 0xFF100706,
            surface = 0xFF150A07,
            raised = 0xFF21120E,
            accent = 0xFFC45132,
            secondary = 0xFFA33A53,
            tertiary = 0xFFFF9A62,
            artworkStops = listOf(0xFFA33A53, 0xFFD25B3F, 0xFFFF9A62),
        )

        val palettes = ResonanceThemeChoice.entries.map(::paletteForTheme)
        assertEquals(palettes.size, palettes.toSet().size)
        palettes.forEach { palette -> assertEquals(Color(0xFF35D477), palette.success) }
        assertNotEquals(paletteForTheme(ResonanceThemeChoice.Midnight), paletteForTheme(ResonanceThemeChoice.Ocean))
    }

    @Test
    fun uiStateDefaultsToMidnight() {
        assertEquals(ResonanceThemeChoice.Midnight, ResonanceUiState().themeChoice)
    }

    @Test
    fun materialRolesAreFullyDerivedFromEachThemePalette() {
        ResonanceThemeChoice.entries.forEach { choice ->
            val palette = paletteForTheme(choice)
            val colors = colorSchemeForPalette(palette)

            assertEquals(palette.accent, colors.primary)
            assertEquals(palette.secondary, colors.secondary)
            assertEquals(palette.tertiary, colors.tertiary)
            assertEquals(palette.raised, colors.primaryContainer)
            assertEquals(palette.raised, colors.secondaryContainer)
            assertEquals(palette.raised, colors.tertiaryContainer)
            assertEquals(palette.tertiary, colors.onPrimaryContainer)
            assertEquals(palette.tertiary, colors.onSecondaryContainer)
            assertEquals(palette.tertiary, colors.onTertiaryContainer)
            assertEquals(palette.background, colors.surfaceContainerLowest)
            assertEquals(palette.panel, colors.surfaceContainerLow)
            assertEquals(palette.surface, colors.surfaceContainer)
            assertEquals(palette.raised, colors.surfaceContainerHigh)
            assertEquals(palette.raised, colors.surfaceContainerHighest)
            assertEquals(palette.accent, colors.surfaceTint)
        }
    }

    @Test
    fun foregroundAccentRolesMeetNormalTextContrast() {
        ResonanceThemeChoice.entries.forEach { choice ->
            val palette = paletteForTheme(choice)
            listOf(palette.background, palette.panel, palette.surface, palette.raised).forEach { surface ->
                assertContrast(choice, palette.tertiary, surface)
            }
            assertContrast(choice, Color.White, palette.accent)
            assertContrast(choice, Color.White, palette.secondary)
        }
    }

    private fun assertPalette(
        choice: ResonanceThemeChoice,
        background: Long,
        panel: Long,
        surface: Long,
        raised: Long,
        accent: Long,
        secondary: Long,
        tertiary: Long,
        artworkStops: List<Long>,
    ) {
        val palette = paletteForTheme(choice)
        assertEquals(Color(background), palette.background)
        assertEquals(Color(panel), palette.panel)
        assertEquals(Color(surface), palette.surface)
        assertEquals(Color(raised), palette.raised)
        assertEquals(Color(accent), palette.accent)
        assertEquals(Color(secondary), palette.secondary)
        assertEquals(Color(tertiary), palette.tertiary)
        assertEquals(artworkStops.map { Color(it) }, palette.artworkStops)
    }

    private fun assertContrast(
        choice: ResonanceThemeChoice,
        foreground: Color,
        background: Color,
    ) {
        val contrast = contrastRatio(foreground, background)
        assertTrue(
            "${choice.label} contrast was $contrast for $foreground on $background",
            contrast >= 4.5,
        )
    }

    private fun contrastRatio(first: Color, second: Color): Double {
        val brighter = maxOf(relativeLuminance(first), relativeLuminance(second))
        val darker = minOf(relativeLuminance(first), relativeLuminance(second))
        return (brighter + .05) / (darker + .05)
    }

    private fun relativeLuminance(color: Color): Double {
        fun linear(component: Float): Double {
            val value = component.toDouble()
            return if (value <= .04045) value / 12.92 else Math.pow((value + .055) / 1.055, 2.4)
        }
        return .2126 * linear(color.red) + .7152 * linear(color.green) + .0722 * linear(color.blue)
    }
}
