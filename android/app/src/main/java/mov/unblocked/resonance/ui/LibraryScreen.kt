package mov.unblocked.resonance.ui

import android.graphics.BitmapFactory
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.Image
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import mov.unblocked.resonance.data.Track
import mov.unblocked.resonance.data.AccountEmailPrivacy
import mov.unblocked.resonance.data.ProfileImageNetworkPolicy
import mov.unblocked.resonance.data.ProfileImagePayloadPolicy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun LibraryScreen(
    state: ResonanceUiState,
    actions: ResonanceActions,
    modifier: Modifier = Modifier,
    onOpenStorage: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    var clipEditorOpen by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current
    val query = remember(state.librarySearch) { state.librarySearch.trim() }
    val tracks = remember(state.tracks, query) {
        if (query.isEmpty()) {
            state.tracks
        } else {
            state.tracks.filter {
                it.title.contains(query, true) || it.artist.contains(query, true) ||
                    it.album.contains(query, true) || it.relativePath.contains(query, true)
            }
        }
    }
    val recentlyAdded = remember(state.tracks) { recentlyAddedTracks(state.tracks) }
    val queueIDs = remember(state.tracks) { state.tracks.map(Track::id) }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.Top,
    ) {
        item(key = "library-header", contentType = "chrome") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Library", fontSize = 36.sp, fontWeight = FontWeight.Bold)
                    Text(
                        "${songCountLabel(state.tracks.size)} on this device",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                    )
                }
                IconButton(
                    onClick = onOpenStorage,
                    modifier = Modifier.size(44.dp).background(Color.White.copy(alpha = .08f), CircleShape),
                ) { Icon(Icons.Default.Storage, "Storage") }
                ProfileButton(
                    state = state,
                    onSettings = onOpenSettings,
                    onClipEditor = { clipEditorOpen = true },
                )
            }
        }
        item(key = "library-header-gap", contentType = "spacer") { Spacer(Modifier.height(16.dp)) }
        item(key = "library-search", contentType = "chrome") {
            OutlinedTextField(
                value = state.librarySearch,
                onValueChange = actions::setLibrarySearch,
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("Search your music") },
                leadingIcon = { Icon(Icons.Default.Search, null) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                shape = RoundedCornerShape(13.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = Color.White.copy(alpha = .055f),
                    unfocusedContainerColor = Color.White.copy(alpha = .055f),
                    unfocusedBorderColor = Color.White.copy(alpha = .08f),
                ),
            )
        }
        item(key = "library-search-gap", contentType = "spacer") { Spacer(Modifier.height(16.dp)) }
        if (query.isEmpty() && recentlyAdded.isNotEmpty()) {
            item(key = "recently-added", contentType = "recently-added") {
                RecentlyAddedSection(
                    tracks = recentlyAdded,
                    queueIDs = queueIDs,
                    state = state,
                    actions = actions,
                )
            }
            item(key = "recently-added-gap", contentType = "spacer") { Spacer(Modifier.height(16.dp)) }
        }
        if (tracks.isEmpty()) {
            item(key = "library-empty", contentType = "empty-state") {
                val emptyState = libraryEmptyStateCopy(hasSongs = state.tracks.isNotEmpty())
                Column(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(
                        Icons.Default.MusicNote,
                        null,
                        Modifier.size(44.dp),
                        tint = MaterialTheme.colorScheme.tertiary,
                    )
                    Text(emptyState.title, style = MaterialTheme.typography.titleMedium)
                    Text(
                        emptyState.detail,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                    )
                }
            }
        } else {
            item(key = "all-songs-header", contentType = "section-header") {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("All Songs", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    Text(
                        tracks.size.toString(),
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                    )
                }
            }
            itemsIndexed(
                items = tracks,
                key = { _, track -> track.id },
                contentType = { _, _ -> "track" },
            ) { index, track ->
                TrackRow(track, state, actions, number = index + 1, queue = tracks)
            }
        }
        item(key = "library-bottom-gap", contentType = "spacer") { Spacer(Modifier.height(8.dp)) }
    }

    if (clipEditorOpen) {
        ClipEditorDialog(state, actions) { clipEditorOpen = false }
    }
}

@Composable
private fun ProfileButton(
    state: ResonanceUiState,
    onSettings: () -> Unit,
    onClipEditor: () -> Unit,
) {
    val profileName = AccountEmailPrivacy.safeDisplayName(
        state.accountDisplayName ?: activeSyncProfileName(state),
        state.accountEmail,
    )
    var expanded by remember { mutableStateOf(false) }
    var isEmailRevealed by remember(state.accountEmail) { mutableStateOf(false) }
    val profileBitmap = rememberAccountImage(state.serverUrl, state.accountImageURL)
    Box {
        IconButton(
            onClick = { expanded = true },
            modifier = Modifier
                .size(44.dp)
                .background(MaterialTheme.colorScheme.secondary, CircleShape)
                .semantics {
                    contentDescription = "Profile: $profileName. Open profile tools"
                },
        ) {
            if (profileBitmap != null) {
                Image(
                    bitmap = profileBitmap,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize().clearAndSetSemantics { },
                )
            } else {
                Text(
                    text = syncProfileInitial(profileName),
                    color = Color.White,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.clearAndSetSemantics { },
                )
            }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            if (state.accountEmail != null) {
                DropdownMenuItem(
                    text = {
                        Text(AccountEmailPrivacy.displayedAddress(state.accountEmail, isEmailRevealed))
                    },
                    onClick = { isEmailRevealed = !isEmailRevealed },
                )
            }
            DropdownMenuItem(
                text = { Text("Clip Editor") },
                leadingIcon = { Icon(Icons.Default.GraphicEq, null) },
                onClick = {
                    expanded = false
                    onClipEditor()
                },
            )
            DropdownMenuItem(
                text = { Text("Settings") },
                leadingIcon = { Icon(Icons.Default.Settings, null) },
                onClick = {
                    expanded = false
                    onSettings()
                },
            )
        }
    }
}

@Composable
private fun rememberAccountImage(
    serverURL: String,
    imageURL: String?,
): androidx.compose.ui.graphics.ImageBitmap? {
    val bitmap by produceState<androidx.compose.ui.graphics.ImageBitmap?>(null, serverURL, imageURL) {
        value = withContext(Dispatchers.IO) {
            loadProfileImageBytes(serverURL, imageURL)?.let { bytes ->
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
            }
        }
    }
    return bitmap
}

/** Fetches a server/Clerk profile image without following an unvalidated redirect. */
internal fun loadProfileImageBytes(
    serverURL: String,
    imageURL: String?,
    connectionFactory: (URL) -> HttpURLConnection = { target ->
        target.openConnection() as HttpURLConnection
    },
): ByteArray? = runCatching {
    var currentURL = ProfileImageNetworkPolicy.resolveURL(serverURL, imageURL)
        ?: return@runCatching null
    for (redirectCount in 0..MAX_PROFILE_IMAGE_REDIRECTS) {
        val connection = connectionFactory(currentURL)
        try {
            connection.requestMethod = "GET"
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = PROFILE_IMAGE_CONNECT_TIMEOUT_MS
            connection.readTimeout = PROFILE_IMAGE_READ_TIMEOUT_MS
            connection.setRequestProperty("Accept", "image/*")
            val responseCode = connection.responseCode
            if (responseCode in PROFILE_IMAGE_REDIRECT_STATUSES) {
                if (redirectCount == MAX_PROFILE_IMAGE_REDIRECTS) {
                    throw IOException("The profile image redirected too many times")
                }
                val location = connection.getHeaderField("Location")
                    ?.trim()
                    ?.takeIf(String::isNotEmpty)
                    ?: throw IOException("The profile image redirect is missing a location")
                currentURL = ProfileImageNetworkPolicy.resolveRedirect(serverURL, currentURL, location)
                    ?: throw IOException("The profile image redirect is not secure")
                continue
            }
            if (responseCode !in 200..299) return@runCatching null
            if (connection.contentLengthLong > ProfileImagePayloadPolicy.MAX_BYTES) {
                return@runCatching null
            }
            val bytes = connection.inputStream.use(ProfileImagePayloadPolicy::readBoundedBytes)
                ?: return@runCatching null
            if (!ProfileImagePayloadPolicy.hasSafeDecodedBounds(bytes)) return@runCatching null
            return@runCatching bytes
        } finally {
            connection.disconnect()
        }
    }
    null
}.getOrNull()

private const val MAX_PROFILE_IMAGE_REDIRECTS = 5
private const val PROFILE_IMAGE_CONNECT_TIMEOUT_MS = 5_000
private const val PROFILE_IMAGE_READ_TIMEOUT_MS = 5_000
private val PROFILE_IMAGE_REDIRECT_STATUSES = setOf(
    HttpURLConnection.HTTP_MOVED_PERM,
    HttpURLConnection.HTTP_MOVED_TEMP,
    HttpURLConnection.HTTP_SEE_OTHER,
    307,
    308,
)

@Composable
private fun RecentlyAddedSection(
    tracks: List<Track>,
    queueIDs: List<String>,
    state: ResonanceUiState,
    actions: ResonanceActions,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Eyebrow("Recently Added")
        LazyRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(tracks, key = Track::id, contentType = { "recent-track" }) { track ->
                Column(
                    modifier = Modifier
                        .width(132.dp)
                        .clickable { actions.playTrack(track.id, queueIDs) },
                    verticalArrangement = Arrangement.spacedBy(7.dp),
                ) {
                    Artwork(
                        path = state.artworkPathsByTrackId[track.id] ?: track.artworkFilename,
                        modifier = Modifier.size(132.dp),
                        showWaveform = state.currentTrackId == track.id && state.isPlaying,
                    )
                    Text(
                        text = track.title,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = track.artist,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                        fontSize = 12.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

internal fun activeSyncProfileName(state: ResonanceUiState): String =
    AccountEmailPrivacy.safeDisplayName(
        state.syncProfiles
        .firstOrNull { it.id == state.syncProfileId }
        ?.name
        ?.trim()
        ?.takeIf(String::isNotEmpty)
            ?: "Default",
        state.accountEmail,
    )

internal fun syncProfileInitial(name: String): String =
    name.trim().firstOrNull(Char::isLetterOrDigit)?.uppercase() ?: "?"

internal fun recentlyAddedTracks(tracks: List<Track>, limit: Int = 6): List<Track> {
    if (limit <= 0 || tracks.isEmpty()) return emptyList()
    if (tracks.size <= limit) return tracks.sortedByDescending(Track::dateAddedEpochMs)

    val recent = ArrayList<Track>(limit)
    for (track in tracks) {
        val insertionIndex = recent.indexOfFirst { candidate ->
            track.dateAddedEpochMs > candidate.dateAddedEpochMs
        }
        when {
            insertionIndex >= 0 -> recent.add(insertionIndex, track)
            recent.size < limit -> recent.add(track)
        }
        if (recent.size > limit) recent.removeAt(recent.lastIndex)
    }
    return recent
}
