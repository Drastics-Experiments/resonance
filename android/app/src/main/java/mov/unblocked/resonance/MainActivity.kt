package mov.unblocked.resonance

import android.Manifest
import android.content.Intent
import android.net.Uri
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
import com.clerk.api.Clerk
import kotlinx.coroutines.launch
import mov.unblocked.resonance.ui.ResonanceApp
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
        lifecycleScope.launch { updateManager.checkForUpdateOnStartup() }
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        if (Build.VERSION.SDK_INT >= 33) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
        viewModel.handleAccountCallback(intent?.data)
        handleListenAlongIntent(intent)
        setContent {
            val state by viewModel.uiState.collectAsStateWithLifecycle()
            val updateState by updateManager.state.collectAsStateWithLifecycle()
            val developerMode by updateManager.developerMode.collectAsStateWithLifecycle()
            LaunchedEffect(Unit) {
                viewModel.importRequests.collect { importLauncher.launch(arrayOf("audio/*", "video/*")) }
            }
            LaunchedEffect(state.isNativeAccountSignInOpen) {
                if (state.isNativeAccountSignInOpen) Clerk.attachActivity(this@MainActivity)
            }
            LaunchedEffect(Unit) {
                viewModel.uploadRequests.collect { uploadLauncher.launch(arrayOf("audio/*", "video/*")) }
            }
            LaunchedEffect(Unit) {
                viewModel.profilePictureRequests.collect { profilePictureLauncher.launch(arrayOf("image/*")) }
            }
            LaunchedEffect(Unit) {
                viewModel.accountBrowserRequests.collect { destination ->
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(destination)))
                }
            }
            ResonanceApp(
                state = state,
                actions = viewModel,
                updateState = updateState,
                developerMode = developerMode,
                onDeveloperModeChanged = ::setDeveloperMode,
                onDownloadUpdate = ::downloadUpdate,
                onInstallUpdate = ::installDownloadedUpdate,
                onDismissUpdate = updateManager::dismiss,
            )
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refreshAccountSessionIfNeeded()
        viewModel.retryRemoteSongMetadataIfNeeded()
        viewModel.syncPlaylistsAutomatically()
        lifecycleScope.launch { updateManager.checkForUpdateIfDue() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        viewModel.handleAccountCallback(intent.data)
        handleListenAlongIntent(intent)
    }

    private fun handleListenAlongIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme != "resonance") return
        val code = when {
            uri.host == "listen" && uri.path == "/join" -> uri.getQueryParameter("code")
            uri.host == "listen-along" -> uri.pathSegments.lastOrNull()
            else -> null
        }
        code?.takeIf(String::isNotBlank)?.let(viewModel::joinListenAlong)
    }

    private fun downloadUpdate(update: AndroidUpdateInfo) {
        lifecycleScope.launch {
            updateManager.downloadUpdate(update)?.let(::launchDownloadedUpdate)
        }
    }

    private fun setDeveloperMode(enabled: Boolean) {
        updateManager.setDeveloperMode(enabled)
        lifecycleScope.launch { updateManager.checkForUpdateOnStartup() }
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
