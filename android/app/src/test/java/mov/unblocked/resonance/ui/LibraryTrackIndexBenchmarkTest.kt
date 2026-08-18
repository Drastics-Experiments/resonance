package mov.unblocked.resonance.ui

import java.io.File
import kotlin.system.measureNanoTime
import mov.unblocked.resonance.data.Track
import org.junit.Assert.assertEquals
import org.junit.Test

class LibraryTrackIndexBenchmarkTest {
    @Test
    fun benchmarkLibrarySearchIndex() {
        val outputPath = System.getenv("RESONANCE_BENCHMARK_OUTPUT") ?: return
        val results = ArrayList<String>()

        for (size in listOf(1_000, 10_000, 50_000)) {
            val tracks = generatedTracks(size)
            val buildIterations = if (size >= 50_000) 7 else 15
            val buildNs = benchmark(buildIterations, warmups = 4) {
                consume(LibraryTrackIndex(tracks).queueIDs.size)
            }
            val index = LibraryTrackIndex(tracks)
            for (query in QUERIES) {
                assertEquals(previousSearch(tracks, query).map(Track::id), index.search(query).map(Track::id))
            }

            val queryIterations = when {
                size >= 50_000 -> 5
                size >= 10_000 -> 15
                else -> 50
            }
            val (baselineNs, indexedNs) = benchmarkPair(
                iterations = queryIterations,
                warmups = 6,
                baseline = {
                    for (query in QUERIES) consume(previousSearch(tracks, query).size)
                },
                candidate = {
                    for (query in QUERIES) consume(index.search(query).size)
                },
            )
            results += """{"dataset_size":$size,"index_build_median_ns":$buildNs,"baseline_query_batch_median_ns":$baselineNs,"indexed_query_batch_median_ns":$indexedNs}"""
        }

        val output = File(outputPath)
        output.parentFile?.mkdirs()
        output.writeText("""{"schema_version":1,"queries_per_batch":${QUERIES.size},"results":[${results.joinToString(",")}]}""" + "\n")
    }

    private fun benchmarkPair(
        iterations: Int,
        warmups: Int,
        baseline: () -> Unit,
        candidate: () -> Unit,
    ): Pair<Long, Long> {
        repeat(warmups) {
            baseline()
            candidate()
        }
        val baselineSamples = ArrayList<Long>(iterations)
        val candidateSamples = ArrayList<Long>(iterations)
        repeat(iterations) { sample ->
            if (sample % 2 == 0) {
                baselineSamples += measureNanoTime(baseline)
                candidateSamples += measureNanoTime(candidate)
            } else {
                candidateSamples += measureNanoTime(candidate)
                baselineSamples += measureNanoTime(baseline)
            }
        }
        return median(baselineSamples) to median(candidateSamples)
    }

    private fun benchmark(iterations: Int, warmups: Int, block: () -> Unit): Long {
        repeat(warmups) { block() }
        return median(LongArray(iterations) { measureNanoTime(block) }.asList())
    }

    private fun previousSearch(tracks: List<Track>, rawQuery: String): List<Track> {
        val query = rawQuery.trim()
        if (query.isEmpty()) return tracks
        return tracks.filter { track ->
            track.title.contains(query, ignoreCase = true) ||
                track.artist.contains(query, ignoreCase = true) ||
                track.album.contains(query, ignoreCase = true) ||
                track.relativePath.contains(query, ignoreCase = true)
        }
    }

    private fun generatedTracks(count: Int): List<Track> = List(count) { index ->
        Track(
            id = "track-$index",
            title = "Song ${index.toString().padStart(6, '0')} ${GENRES[index % GENRES.size]}",
            artist = "Artist ${index % 257}",
            album = "Album ${index % 43}",
            relativePath = "folder/${index % 97}/track-$index.m4a",
        )
    }

    private fun median(values: List<Long>): Long {
        val sorted = values.sorted()
        return sorted[sorted.size / 2]
    }

    private companion object {
        @Volatile
        private var blackhole = 0L

        private fun consume(value: Int) {
            blackhole = blackhole xor value.toLong()
        }

        private val QUERIES = listOf(
            "song 000999",
            "artist 17",
            "album 9",
            "folder/33",
            "electronic",
            "definitely-not-present",
        )
        private val GENRES = listOf("Electronic", "Ambient", "Pop", "Rock", "Jazz", "Classical", "Hip Hop", "Soundtrack")
    }
}
