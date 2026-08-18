import Foundation
import XCTest
@testable import Resonance

final class MobileLocalImportTests: XCTestCase {
    func testYouTubePlaylistURLCanonicalizesListLinks() throws {
        let result = try XCTUnwrap(
            try LocalImportURL.youtubePlaylist(
                "https://www.youtube.com/watch?v=jNQXAC9IVRw&list=PL1234567890abcdefghijklmnop"
            )
        )
        XCTAssertEqual(result.playlistID, "PL1234567890abcdefghijklmnop")
        XCTAssertEqual(
            result.url.absoluteString,
            "https://www.youtube.com/playlist?list=PL1234567890abcdefghijklmnop"
        )
        XCTAssertNil(try LocalImportURL.youtubePlaylist("https://www.youtube.com/watch?v=jNQXAC9IVRw"))
    }

    func testYouTubePlaylistParserKeepsUnavailableItemsAndContinuation() throws {
        let playlistID = "PL1234567890abcdefghijklmnop"
        let data: [String: Any] = [
            "playlistMetadataRenderer": [
                "playlistId": playlistID,
                "title": "Road Trip",
            ],
            "playlistHeaderRenderer": [
                "ownerText": ["simpleText": "Resonance Radio"],
            ],
            "playlistVideoRenderer": [
                "videoId": "jNQXAC9IVRw",
                "title": ["simpleText": "First Song"],
                "shortBylineText": ["simpleText": "Artist One"],
                "lengthText": ["simpleText": "3:21"],
                "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg"]]],
                "index": ["simpleText": "1"],
            ],
            "unavailableVideo": [
                "playlistVideoRenderer": [
                    "videoId": "dQw4w9WgXcQ",
                    "title": ["simpleText": "Unavailable Song"],
                    "isPlayable": false,
                    "index": ["simpleText": "2"],
                ],
            ],
            "continuationItemRenderer": [
                "continuationEndpoint": [
                    "continuationCommand": ["token": "continuation-token"],
                ],
            ],
        ]

        let result = try LocalImportParser.youtubePlaylistData(
            data,
            expectedPlaylistID: playlistID
        )
        XCTAssertEqual(result.title, "Road Trip")
        XCTAssertEqual(result.author, "Resonance Radio")
        XCTAssertEqual(result.items.map(\.videoID), ["jNQXAC9IVRw"])
        XCTAssertEqual(result.items.first?.durationSeconds, 201)
        XCTAssertEqual(result.skippedItems.count, 1)
        XCTAssertEqual(result.skippedItems.first?.position, 2)
        XCTAssertEqual(result.skippedItems.first?.reason, "Unavailable on YouTube")
        XCTAssertEqual(result.continuation, "continuation-token")
    }

    func testYouTubePlaylistParserSupportsModernLockupItems() throws {
        let result = try LocalImportParser.youtubePlaylistData(
            [
                "contents": [[
                    "lockupViewModel": [
                        "contentId": "jNQXAC9IVRw",
                        "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                        "contentImage": [
                            "thumbnailViewModel": [
                                "image": [
                                    "sources": [[
                                        "url": "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg",
                                        "width": 480,
                                    ]],
                                ],
                                "overlays": [[
                                    "thumbnailBottomOverlayViewModel": [
                                        "badges": [[
                                            "thumbnailBadgeViewModel": ["text": "0:19"],
                                        ]],
                                    ],
                                ]],
                            ],
                        ],
                        "metadata": [
                            "lockupMetadataViewModel": [
                                "title": ["content": "Me at the zoo"],
                                "metadata": [
                                    "contentMetadataViewModel": [
                                        "metadataRows": [[
                                            "metadataParts": [["text": ["content": "Jawed Karim"]]],
                                        ]],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]],
            ],
            expectedPlaylistID: "PL1234567890abcdefghijklmnop"
        )

        XCTAssertEqual(result.items.map(\.videoID), ["jNQXAC9IVRw"])
        XCTAssertEqual(result.items.first?.title, "Me at the zoo")
        XCTAssertEqual(result.items.first?.artist, "Jawed Karim")
        XCTAssertEqual(result.items.first?.durationSeconds, 19)
    }

    func testYouTubePlaylistParserRejectsWrongPlaylist() {
        let data: [String: Any] = [
            "playlistMetadataRenderer": [
                "playlistId": "PLwrong1234567890",
                "title": "Wrong playlist",
            ],
        ]
        XCTAssertThrowsError(
            try LocalImportParser.youtubePlaylistData(
                data,
                expectedPlaylistID: "PLexpected1234567890"
            )
        ) { error in
            XCTAssertEqual((error as? LocalImportError)?.code, "YOUTUBE_PLAYLIST_MISMATCH")
        }
    }
}
