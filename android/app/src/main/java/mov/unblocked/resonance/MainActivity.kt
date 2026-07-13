package mov.unblocked.resonance

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.getValue
import androidx.core.app.ActivityCompat
import mov.unblocked.resonance.ui.ResonanceApp
import mov.unblocked.resonance.ui.ResonanceTheme

class MainActivity : ComponentActivity() {
    private val viewModel: ResonanceViewModel by viewModels()

    private val importLauncher = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        viewModel.importUris(uris)
    }
    private val uploadLauncher = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        viewModel.uploadUris(uris)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        if (Build.VERSION.SDK_INT >= 33) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
        setContent {
            val state by viewModel.uiState.collectAsStateWithLifecycle()
            LaunchedEffect(Unit) {
                viewModel.importRequests.collect { importLauncher.launch(arrayOf("audio/*")) }
            }
            LaunchedEffect(Unit) {
                viewModel.uploadRequests.collect { uploadLauncher.launch(arrayOf("audio/*")) }
            }
            ResonanceTheme {
                ResonanceApp(state = state, actions = viewModel)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.syncPlaylistsAutomatically()
    }
}
