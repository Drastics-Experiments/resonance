package mov.unblocked.resonance.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp

@Composable
internal fun AppearanceDialog(
    selected: ResonanceThemeChoice,
    onSelected: (ResonanceThemeChoice) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Appearance") },
        text = {
            Column(
                modifier = Modifier.selectableGroup(),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ResonanceThemeChoice.entries.forEach { choice ->
                    ThemeChoiceRow(
                        choice = choice,
                        selected = selected == choice,
                        onSelected = { onSelected(choice) },
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = onDismiss,
                colors = ButtonDefaults.textButtonColors(
                    contentColor = MaterialTheme.colorScheme.tertiary,
                ),
            ) { Text("Done") }
        },
    )
}

@Composable
private fun ThemeChoiceRow(
    choice: ResonanceThemeChoice,
    selected: Boolean,
    onSelected: () -> Unit,
) {
    val palette = paletteForTheme(choice)
    val shape = RoundedCornerShape(14.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .border(
                width = 1.dp,
                color = if (selected) {
                    MaterialTheme.colorScheme.tertiary.copy(alpha = .82f)
                } else {
                    MaterialTheme.colorScheme.onSurface.copy(alpha = .10f)
                },
                shape = shape,
            )
            .selectable(
                selected = selected,
                onClick = onSelected,
                role = Role.RadioButton,
            )
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        RadioButton(
            selected = selected,
            onClick = null,
            colors = RadioButtonDefaults.colors(
                selectedColor = MaterialTheme.colorScheme.tertiary,
                unselectedColor = MaterialTheme.colorScheme.onSurfaceVariant,
            ),
        )
        Text(choice.label, modifier = Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            listOf(palette.background, palette.accent, palette.secondary, palette.tertiary).forEach { color ->
                Box(
                    Modifier
                        .size(17.dp)
                        .background(color, CircleShape)
                        .border(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = .16f), CircleShape),
                )
            }
        }
    }
}
