package mov.unblocked.resonance.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException

class StreamRangePolicyTest {
    @Test
    fun validatesExactPartialResponse() {
        val range = StreamRangePolicy.validatePartialResponse(
            contentRange = "bytes 1024-2047/4096",
            requestedStart = 1024,
            requestedLength = 1024,
            responseLength = 1024,
        )
        assertEquals(1024L, range.start)
        assertEquals(2047L, range.endInclusive)
        assertEquals(4096L, range.totalBytes)
        assertEquals(1024L, range.length)
    }

    @Test
    fun rejectsMissingShiftedAndLengthMismatchedRanges() {
        expectFailure("invalid Content-Range") {
            StreamRangePolicy.validatePartialResponse(null, 0, null, null)
        }
        expectFailure("does not match") {
            StreamRangePolicy.validatePartialResponse("bytes 1-100/1000", 0, null, 100)
        }
        expectFailure("length does not match") {
            StreamRangePolicy.validatePartialResponse("bytes 0-99/1000", 0, null, 99)
        }
        expectFailure("more bytes") {
            StreamRangePolicy.validatePartialResponse("bytes 0-99/1000", 0, 50, 100)
        }
    }

    @Test
    fun partialRemainingLengthUsesTheValidatedBodyInsteadOfTheLargerRequest() {
        val shorter = StreamRangePolicy.validatePartialResponse(
            contentRange = "bytes 1024-1535/4096",
            requestedStart = 1024,
            requestedLength = 1024,
            responseLength = 512,
        )
        assertEquals(
            512L,
            StreamRangePolicy.remainingLength(
                requestedLength = 1024,
                responseLength = 512,
                requestedPosition = 1024,
                partialRange = shorter,
            ),
        )
        assertEquals(
            1024L,
            StreamRangePolicy.remainingLength(1024, 4096, 1024, null),
        )
        assertEquals(
            512L,
            StreamRangePolicy.remainingLength(1024, 1536, 1024, null),
        )
    }

    private fun expectFailure(message: String, block: () -> Unit) {
        try {
            block()
            fail("Expected IOException containing $message")
        } catch (error: IOException) {
            assertTrue(error.message.orEmpty().contains(message))
        }
    }
}
