import CoreGraphics
import XCTest
@testable import Resonance

final class ArtworkCroppingTests: XCTestCase {
    func testCacheKeyUsesOwnerAndBoundedArtworkFingerprint() {
        let artwork = Data(0..<64)
        let sameKey = ArtworkCropping.cacheKey(ownerID: "track-a", data: artwork)
        var changedArtwork = artwork
        changedArtwork[changedArtwork.index(changedArtwork.startIndex, offsetBy: 32)] = 255

        XCTAssertEqual(sameKey, ArtworkCropping.cacheKey(ownerID: "track-a", data: artwork))
        XCTAssertNotEqual(sameKey, ArtworkCropping.cacheKey(ownerID: "track-b", data: artwork))
        XCTAssertNotEqual(
            sameKey,
            ArtworkCropping.cacheKey(ownerID: "track-a", data: changedArtwork)
        )
    }

    func testSquareArtworkIsLeftUnchanged() throws {
        let image = try makeArtwork(width: 320, height: 320)
        XCTAssertEqual(
            ArtworkCropping.squareCropRect(in: image),
            CGRect(x: 0, y: 0, width: 320, height: 320)
        )
    }

    func testRectangularArtworkUsesACenteredSquareCrop() throws {
        let image = try makeArtwork(width: 640, height: 480)
        let crop = ArtworkCropping.squareCropRect(in: image)
        XCTAssertEqual(crop.origin.x, 80, accuracy: 1)
        XCTAssertEqual(crop.origin.y, 0, accuracy: 1)
        XCTAssertEqual(crop.width, 480, accuracy: 1)
        XCTAssertEqual(crop.height, 480, accuracy: 1)
    }

    func testSymmetricSideBarsAreRemovedBeforeCropping() throws {
        let image = try makeArtwork(width: 640, height: 480, horizontalBorder: 80)
        let crop = ArtworkCropping.squareCropRect(in: image)
        XCTAssertEqual(crop.origin.x, 80, accuracy: 5)
        XCTAssertEqual(crop.origin.y, 0, accuracy: 5)
        XCTAssertEqual(crop.width, 480, accuracy: 5)
        XCTAssertEqual(crop.height, 480, accuracy: 5)
    }

    func testSymmetricTopAndBottomBarsAreRemovedBeforeCropping() throws {
        let image = try makeArtwork(width: 480, height: 640, verticalBorder: 80)
        let crop = ArtworkCropping.squareCropRect(in: image)
        XCTAssertEqual(crop.origin.x, 0, accuracy: 5)
        XCTAssertEqual(crop.origin.y, 80, accuracy: 5)
        XCTAssertEqual(crop.width, 480, accuracy: 5)
        XCTAssertEqual(crop.height, 480, accuracy: 5)
    }

    func testLandscapeLetterboxBarsAreRemovedBeforeSquareCropping() throws {
        let image = try makeArtwork(width: 640, height: 480, verticalBorder: 60)
        let crop = ArtworkCropping.squareCropRect(in: image)
        XCTAssertEqual(crop.origin.x, 140, accuracy: 5)
        XCTAssertEqual(crop.origin.y, 60, accuracy: 5)
        XCTAssertEqual(crop.width, 360, accuracy: 5)
        XCTAssertEqual(crop.height, 360, accuracy: 5)
    }

    private func makeArtwork(
        width: Int,
        height: Int,
        horizontalBorder: Int = 0,
        verticalBorder: Int = 0
    ) throws -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let isBorder = x < horizontalBorder
                    || x >= width - horizontalBorder
                    || y < verticalBorder
                    || y >= height - verticalBorder
                if isBorder {
                    pixels[offset] = 8
                    pixels[offset + 1] = 8
                    pixels[offset + 2] = 8
                } else {
                    pixels[offset] = UInt8(32 + (x * 17 + y * 3) % 190)
                    pixels[offset + 1] = UInt8(32 + (x * 5 + y * 19) % 190)
                    pixels[offset + 2] = UInt8(32 + (x * 11 + y * 7) % 190)
                }
                pixels[offset + 3] = 255
            }
        }

        let image = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        return try XCTUnwrap(image)
    }
}
