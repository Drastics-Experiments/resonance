package mov.unblocked.resonance

import android.Manifest
import android.os.Build
import android.os.Bundle
import java.io.File
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
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import mov.unblocked.resonance.ui.ResonanceApp
import mov.unblocked.resonance.ui.ResonanceTheme
import mov.unblocked.resonance.update.AndroidInstallRequest
import mov.unblocked.resonance.update.AndroidUpdateInfo
import mov.unblocked.resonance.update.AndroidUpdateManager

class MainActivity : ComponentActivity() {
    private val viewModel: ResonanceViewModel by viewModels()
    private lateinit var updateManager: AndroidUpdateManager
    private var pendingUpdateFile: File? = null

    private val importLauncher = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        viewModel.importUris(uris)
    }
    private val uploadLauncher = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        viewModel.uploadUris(uris)
    }
    private val profilePictureLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(viewModel::setProfilePicture)
    }
    private val unknownSourceLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        val file = pendingUpdateFile ?: return@registerForActivityResult
        pendingUpdateFile = null
        if (packageManager.canRequestPackageInstalls()) {
            launchDownloadedUpdate(file)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val updateManifestUrl = if (BuildConfig.DEBUG) {
            intent.getStringExtra(DEBUG_UPDATE_MANIFEST_EXTRA)
        } else {
            null
        }
        updateManager = AndroidUpdateManager(
            context = applicationContext,
            manifestUrl = updateManifestUrl ?: AndroidUpdateManager.DEFAULT_MANIFEST_URL,
        )
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        if (Build.VERSION.SDK_INT >= 33) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
        setContent {
            val state by viewModel.uiState.collectAsStateWithLifecycle()
            val updateState by updateManager.state.collectAsStateWithLifecycle()
            LaunchedEffect(Unit) {
                viewModel.importRequests.collect { importLauncher.launch(arrayOf("audio/*", "video/*")) }
            }
            LaunchedEffect(Unit) {
                viewModel.uploadRequests.collect { uploadLauncher.launch(arrayOf("audio/*", "video/*")) }
            }
            LaunchedEffect(Unit) {
                viewModel.profilePictureRequests.collect { profilePictureLauncher.launch(arrayOf("image/*")) }
            }
            ResonanceTheme {
                ResonanceApp(
                    state = state,
                    actions = viewModel,
                    updateState = updateState,
                    onDownloadUpdate = ::downloadUpdate,
                    onInstallUpdate = ::installDownloadedUpdate,
                    onDismissUpdate = updateManager::dismiss,
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.syncPlaylistsAutomatically()
        lifecycleScope.launch { updateManager.checkForUpdateIfDue() }
    }

    private fun downloadUpdate(update: AndroidUpdateInfo) {
        lifecycleScope.launch {
            updateManager.downloadUpdate(update)?.let(::launchDownloadedUpdate)
        }
    }

    private fun installDownloadedUpdate(update: AndroidUpdateInfo) {
        val file = updateManager.downloadedFile(update)
        if (file == null) {
            downloadUpdate(update)
        } else {
            launchDownloadedUpdate(file)
        }
    }

    private fun launchDownloadedUpdate(file: File) {
        runCatching { updateManager.createInstallRequest(file) }
            .onSuccess { request ->
                when (request) {
                    is AndroidInstallRequest.Install -> startActivity(request.intent)
                    is AndroidInstallRequest.AllowUnknownSource -> {
                        pendingUpdateFile = file
                        unknownSourceLauncher.launch(request.intent)
                    }
                }
            }
            .onFailure(updateManager::reportInstallFailure)
    }

    private companion object {
        const val DEBUG_UPDATE_MANIFEST_EXTRA = "mov.unblocked.resonance.DEBUG_UPDATE_MANIFEST_URL"
    }
}
