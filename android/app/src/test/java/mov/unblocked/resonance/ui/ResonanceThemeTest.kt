package mov.unblocked.resonance.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Test

class ResonanceThemeTest {
    @Test
    fun themeChoicesHaveStableStorageIdsAndLabels() {
        assertEquals(
            listOf("midnight", "ocean", "forest", "sunset"),
            ResonanceThemeChoice.entries.map(ResonanceThemeChoice::storageID),
        )
        assertEquals(
            listOf("Midnight", "Ocean", "Forest", "Sunset"),
            ResonanceThemeChoice.entries.map(ResonanceThemeChoice::label),
        )
    }

    @Test
    fun storedThemeParsingIsTolerantAndFallsBackToMidnight() {
        assertEquals(ResonanceThemeChoice.Ocean, ResonanceThemeChoice.fromStorageID("  OCEAN "))
        assertEquals(ResonanceThemeChoice.Midnight, ResonanceThemeChoice.fromStorageID(null))
        assertEquals(ResonanceThemeChoice.Midnight, ResonanceThemeChoice.fromStorageID("future"))
    }

    @Test
    fun palettesMatchSharedDesktopColors() {
        val midnight = paletteForTheme(ResonanceThemeChoice.Midnight)
        val ocean = paletteForTheme(ResonanceThemeChoice.Ocean)
        val forest = paletteForTheme(ResonanceThemeChoice.Forest)
        val sunset = paletteForTheme(ResonanceThemeChoice.Sunset)

        assertEquals(Color(0xFF020305), midnight.background)
        assertEquals(Color(0xFF7547FF), midnight.accent)
        assertEquals(Color(0xFF02070D), ocean.background)
        assertEquals(Color(0xFF1769C2), ocean.accent)
        assertEquals(Color(0xFF020805), forest.background)
        assertEquals(Color(0xFF198754), forest.accent)
        assertEquals(Color(0xFF0A0403), sunset.background)
        assertEquals(Color(0xFFC45132), sunset.accent)
        assertEquals(4, setOf(midnight, ocean, forest, sunset).size)
    }

    @Test
    fun uiStateDefaultsToMidnight() {
        assertEquals(ResonanceThemeChoice.Midnight, ResonanceUiState().themeChoice)
    }
}
