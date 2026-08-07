package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteIdentityPolicyTest {
    @Test
    fun sameSongIdFromDifferentServersAndProfilesRemainsDistinct() {
        val active = remoteTrack("active", "https://music.example", "default", "song-1")
        val otherProfile = remoteTrack("profile", "https://music.example", "family", "song-1")
        val otherServer = remoteTrack("server", "https://other.example", "default", "song-1")

        assertNotEquals(
            RemoteTrackIdentityPolicy.identity(active)?.key,
            RemoteTrackIdentityPolicy.identity(otherProfile)?.key,
        )
        assertNotEquals(
            RemoteTrackIdentityPolicy.identity(active)?.key,
            RemoteTrackIdentityPolicy.identity(otherServer)?.key,
        )
        assertEquals(3, RemoteTrackIdentityPolicy.deduplicate(listOf(active, otherProfile, otherServer)).size)
        assertTrue(RemoteTrackIdentityPolicy.matches(active, "https://MUSIC.example/anything", "default", "song-1"))
        assertFalse(RemoteTrackIdentityPolicy.matches(otherProfile, "https://music.example", "default", "song-1"))
        assertFalse(RemoteTrackIdentityPolicy.matches(otherServer, "https://music.example", "default", "song-1"))
    }

    @Test
    fun associationAdoptionCannotRebindAnotherProfileOrServer() {
        val original = remoteTrack("download", "https://music.example", "default", "song-a")

        listOf(
            "https://music.example" to "family",
            "https://other.example" to "default",
        ).forEach { (server, profile) ->
            val failure = runCatching {
                RemoteTrackIdentityPolicy.withAssociation(original, "song-b", server, profile)
            }.exceptionOrNull()

            assertTrue(failure is RemoteTrackAssociationConflictException)
            assertTrue(failure?.message.orEmpty().contains("kept that link unchanged"))
        }

        assertEquals("song-a", original.remoteID)
        assertEquals("https://music.example", original.sourceServer)
        assertEquals("default", original.syncProfileID)
    }

    @Test
    fun associationAdoptionAllowsLocalTracksAndSameContextReconciliation() {
        val local = Track(id = "local", title = "Local", relativePath = "local.mp3")
        val associated = RemoteTrackIdentityPolicy.withAssociation(
            local,
            "song-a",
            "https://music.example/library",
            "default",
        )
        val reconciled = RemoteTrackIdentityPolicy.withAssociation(
            associated,
            "song-b",
            "https://MUSIC.example/another-path",
            "default",
        )

        assertEquals("song-b", reconciled.remoteID)
        assertEquals("https://MUSIC.example/another-path", reconciled.sourceServer)
        assertEquals("default", reconciled.syncProfileID)
    }

    @Test
    fun sameContextDuplicateRemapsEveryFavoriteAndPlaylistReference() {
        val retained = remoteTrack("retained", "https://music.example", "default", "song-1")
        val duplicate = remoteTrack("duplicate", "https://music.example", "default", "song-1")
        val profileKey = requireNotNull(
            RemoteTrackIdentityPolicy.contextKey("https://music.example", "default"),
        )
        val library = StoredLibrary(
            tracks = listOf(retained, duplicate),
            playlists = listOf(
                Playlist(name = "Liked Songs", isSystem = true),
                Playlist(id = "mix", name = "Mix", trackIDs = listOf(duplicate.id)),
            ),
            favorites = setOf(duplicate.id),
            profileStates = mapOf(
                profileKey to ProfileLibraryState(
                    playlists = listOf(Playlist(id = "saved", name = "Saved", trackIDs = listOf(duplicate.id))),
                    favorites = setOf(duplicate.id),
                ),
            ),
        )

        val reconciled = RemoteTrackIdentityPolicy.reconcileLibraryTracks(library)

        assertEquals(listOf(retained.id), reconciled.tracks.map(Track::id))
        assertEquals(setOf(retained.id), reconciled.favorites)
        assertEquals(listOf(retained.id), reconciled.playlists.first { it.id == "mix" }.trackIDs)
        assertEquals(setOf(retained.id), reconciled.profileStates.getValue(profileKey).favorites)
        assertEquals(
            listOf(retained.id),
            reconciled.profileStates.getValue(profileKey).playlists.single().trackIDs,
        )
    }

    @Test
    fun profileSwitchRoundTripsUnsyncedStateInsteadOfDiscardingIt() {
        val local = Track(id = "local", title = "Local", relativePath = "local.mp3")
        val playlist = Playlist(id = "mix", name = "Unsynced mix", trackIDs = listOf(local.id))
        val initial = StoredLibrary(
            tracks = listOf(local),
            playlists = listOf(Playlist(id = "liked", name = "Liked Songs", trackIDs = listOf(local.id), isSystem = true), playlist),
            favorites = setOf(local.id),
            serverURL = "https://music.example",
            syncProfileID = "default",
            dirtyPlaylistIDs = setOf(playlist.id),
            deletedPlaylistIDs = setOf("deleted-remote-playlist"),
            likesDirty = true,
        )

        val other = ProfileLibraryStatePolicy.switchContext(initial, "https://music.example", "other")
        assertEquals("other", other.syncProfileID)
        assertTrue(other.playlists.none { it.id == playlist.id })
        assertTrue("Device-local favorites remain available", local.id in other.favorites)

        val restored = ProfileLibraryStatePolicy.switchContext(other, "https://music.example", "default")
        assertEquals(listOf("liked", "mix"), restored.playlists.map(Playlist::id))
        assertEquals(setOf("mix"), restored.dirtyPlaylistIDs)
        assertEquals(setOf("deleted-remote-playlist"), restored.deletedPlaylistIDs)
        assertTrue(restored.likesDirty)
    }

    @Test
    fun remoteLikesPlaylistsAndClipMutationsRemainProfileScoped() {
        val local = Track(id = "local", title = "Local", relativePath = "local.mp3")
        val defaultRemote = remoteTrack("default-song", "https://music.example", "default", "same-id")
        val familyRemote = remoteTrack("family-song", "https://music.example", "family", "same-id")
        val defaultClipKey = requireNotNull(
            RemoteTrackIdentityPolicy.contextKey("https://music.example", "default"),
        ) + "|remote:same-id"
        val defaultPlaylist = Playlist(id = "default-mix", name = "Default mix", trackIDs = listOf(defaultRemote.id))
        val initial = StoredLibrary(
            tracks = listOf(local, defaultRemote, familyRemote),
            playlists = listOf(Playlist(name = "Liked Songs", isSystem = true), defaultPlaylist),
            favorites = setOf(local.id, defaultRemote.id),
            serverURL = "https://music.example",
            syncProfileID = "default",
            dirtyPlaylistIDs = setOf(defaultPlaylist.id),
            remoteLikedSongIDs = setOf(defaultRemote.remoteID!!),
            dirtyRemoteLikeSongIDs = setOf(defaultRemote.remoteID),
            likesDirty = true,
            clipRanges = mapOf(defaultClipKey to ClipRange(1_000L, 10_000L)),
            dirtyClipRangeKeys = setOf(defaultClipKey),
        )

        val family = ProfileLibraryStatePolicy.switchContext(initial, "https://music.example", "family")
        assertEquals(setOf(local.id), family.favorites)
        assertTrue(family.playlists.none { it.id == defaultPlaylist.id })
        assertTrue(family.remoteLikedSongIDs.orEmpty().isEmpty())
        assertTrue(family.clipRanges.isEmpty())

        val familyPlaylist = Playlist(id = "family-mix", name = "Family mix", trackIDs = listOf(familyRemote.id))
        val changedFamily = family.copy(
            playlists = family.playlists + familyPlaylist,
            favorites = family.favorites + familyRemote.id,
            dirtyPlaylistIDs = setOf(familyPlaylist.id),
            remoteLikedSongIDs = setOf(familyRemote.remoteID!!),
            dirtyRemoteLikeSongIDs = setOf(familyRemote.remoteID),
            likesDirty = true,
        )
        val restoredDefault = ProfileLibraryStatePolicy.switchContext(
            changedFamily,
            "https://music.example",
            "default",
        )
        assertEquals(setOf(local.id, defaultRemote.id), restoredDefault.favorites)
        assertEquals(setOf(defaultPlaylist.id), restoredDefault.dirtyPlaylistIDs)
        assertEquals(setOf(defaultRemote.remoteID), restoredDefault.remoteLikedSongIDs)
        assertEquals(setOf(defaultClipKey), restoredDefault.dirtyClipRangeKeys)
        assertTrue(restoredDefault.playlists.none { it.id == familyPlaylist.id })

        val restoredFamily = ProfileLibraryStatePolicy.switchContext(
            restoredDefault,
            "https://music.example",
            "family",
        )
        assertEquals(setOf(local.id, familyRemote.id), restoredFamily.favorites)
        assertEquals(setOf(familyPlaylist.id), restoredFamily.dirtyPlaylistIDs)
        assertEquals(setOf(familyRemote.remoteID), restoredFamily.remoteLikedSongIDs)
        assertTrue(restoredFamily.playlists.none { it.id == defaultPlaylist.id })
    }

    @Test
    fun serverOriginsNormalizeDefaultPortsAndIgnorePaths() {
        assertEquals(
            "https://music.example:443#profile=default",
            RemoteTrackIdentityPolicy.contextKey("https://MUSIC.example/library", "default"),
        )
        assertEquals(
            RemoteTrackIdentityPolicy.contextKey("https://music.example", "default"),
            RemoteTrackIdentityPolicy.contextKey("https://music.example:443/anything", "default"),
        )
    }

    private fun remoteTrack(id: String, server: String, profile: String, songID: String) = Track(
        id = id,
        title = id,
        relativePath = "$id.mp3",
        remoteID = songID,
        sourceServer = server,
        syncProfileID = profile,
    )
}
