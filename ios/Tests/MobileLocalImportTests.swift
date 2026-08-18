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

    func testYouTubePlaylistParserAdvancesPastExplicitProviderIndex() throws {
        let playlistID = "PL1234567890abcdefghijklmnop"
        let result = try LocalImportParser.youtubePlaylistData(
            [
                "contents": [
                    [
                        "playlistVideoRenderer": [
                            "videoId": "jNQXAC9IVRw",
                            "title": ["simpleText": "Provider position seven"],
                            "isPlayable": true,
                            "index": ["simpleText": "7"],
                        ],
                    ],
                    [
                        "playlistVideoRenderer": [
                            "videoId": "dQw4w9WgXcQ",
                            "title": ["simpleText": "Unavailable after explicit position"],
                            "isPlayable": false,
                        ],
                    ],
                ],
            ],
            expectedPlaylistID: playlistID
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.skippedItems.map(\.position), [8])
        XCTAssertEqual(result.nextPosition, 9)

        let continuationOffset = max(
            result.nextPosition - 1,
            result.items.count + result.skippedItems.count
        )
        XCTAssertEqual(continuationOffset, 8)
        let continuation = try LocalImportParser.youtubePlaylistData(
            [
                "contents": [[
                    "playlistVideoRenderer": [
                        "videoId": "dQw4w4WgXcQ",
                        "title": ["simpleText": "Next continuation row"],
                        "isPlayable": false,
                    ],
                ]],
            ],
            expectedPlaylistID: playlistID,
            positionOffset: continuationOffset
        )
        XCTAssertEqual(continuation.skippedItems.map(\.position), [9])
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

    func testYouTubePlaylistParserSkipsMalformedLockupAndAdvancesPosition() throws {
        let playlistID = "PL1234567890abcdefghijklmnop"
        let validID = "jNQXAC9IVRw"

        func lockup(_ contentID: String?) -> [String: Any] {
            var viewModel: [String: Any] = [
                "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                "metadata": [
                    "lockupMetadataViewModel": [
                        "title": ["content": "Lockup song"],
                    ],
                ],
            ]
            if let contentID {
                viewModel["contentId"] = contentID
            }
            return ["lockupViewModel": viewModel]
        }

        let result = try LocalImportParser.youtubePlaylistData(
            ["contents": [lockup(nil), lockup(validID)]],
            expectedPlaylistID: playlistID
        )

        XCTAssertEqual(result.items.map(\.videoID), [validID])
        XCTAssertEqual(result.skippedItems.map(\.position), [1])
        XCTAssertEqual(result.skippedItems.first?.reason, "Missing public video metadata")
        XCTAssertEqual(result.unavailableCount, 1)
    }

    func testYouTubePlaylistLimitKeepsPlayableRowsAfterUnavailableRows() throws {
        let playlistID = "PL1234567890abcdefghijklmnop"
        var contents: [[String: Any]] = (1...500).map { index in
            [
                "playlistVideoRenderer": [
                    "videoId": "dQw4w9WgXcQ",
                    "title": ["simpleText": "Unavailable \(index)"],
                    "isPlayable": false,
                ],
            ]
        }
        contents.append([
            "playlistVideoRenderer": [
                "videoId": "jNQXAC9IVRw",
                "title": ["simpleText": "Playable continuation"],
                "shortBylineText": ["simpleText": "Artist"],
                "isPlayable": true,
            ],
        ])

        let page = try LocalImportParser.youtubePlaylistData(
            ["contents": contents],
            expectedPlaylistID: playlistID
        )
        let rows = LocalImportYouTubePlaylistLimitPolicy.takeRows(
            items: page.items,
            skippedItems: page.skippedItems,
            maximum: LocalImportYouTubePlaylistLimitPolicy.maxItems,
            startingPosition: 1
        )

        XCTAssertEqual(page.skippedItems.count, 500)
        XCTAssertEqual(rows.items.map(\.videoID), ["jNQXAC9IVRw"])
        XCTAssertEqual(rows.skippedItems.count, 500)
        XCTAssertFalse(rows.truncated)
    }

    func testYouTubePlaylistLimitAllowsPlayableContinuationAfterUnavailableRows() throws {
        let playlistID = "PL1234567890abcdefghijklmnop"
        let unavailableRows: [[String: Any]] = (1...500).map { index in
            [
                "playlistVideoRenderer": [
                    "videoId": "dQw4w9WgXcQ",
                    "title": ["simpleText": "Unavailable \(index)"],
                    "isPlayable": false,
                ],
            ]
        }
        var firstContents = unavailableRows
        firstContents.append([
            "continuationItemRenderer": [
                "continuationEndpoint": [
                    "continuationCommand": ["token": "continuation-token"],
                ],
            ],
        ])
        let firstPage = try LocalImportParser.youtubePlaylistData(
            ["contents": firstContents],
            expectedPlaylistID: playlistID
        )
        XCTAssertEqual(firstPage.continuation, "continuation-token")
        let firstRows = LocalImportYouTubePlaylistLimitPolicy.takeRows(
            items: firstPage.items,
            skippedItems: firstPage.skippedItems,
            maximum: LocalImportYouTubePlaylistLimitPolicy.maxItems,
            startingPosition: 1
        )
        XCTAssertTrue(firstRows.items.isEmpty)
        XCTAssertEqual(firstRows.skippedItems.count, 500)

        let offset = firstRows.items.count + firstRows.skippedItems.count
        let continuationPage = try LocalImportParser.youtubePlaylistData(
            ["contents": [[
                "playlistVideoRenderer": [
                    "videoId": "jNQXAC9IVRw",
                    "title": ["simpleText": "Playable continuation"],
                    "shortBylineText": ["simpleText": "Artist"],
                    "isPlayable": true,
                ],
            ]]],
            expectedPlaylistID: playlistID,
            positionOffset: offset
        )
        let continuationRows = LocalImportYouTubePlaylistLimitPolicy.takeRows(
            items: continuationPage.items,
            skippedItems: continuationPage.skippedItems,
            maximum: LocalImportYouTubePlaylistLimitPolicy.maxItems - firstRows.items.count,
            startingPosition: offset + 1
        )

        XCTAssertEqual(continuationRows.items.map(\.videoID), ["jNQXAC9IVRw"])
        XCTAssertEqual(continuationRows.items.first?.title, "Playable continuation")
    }

    func testYouTubePlaylistResolutionPreservesExplicitProviderPositions() throws {
        let playlistID = "PL1234567890abcdefghijklmnop"
        let page = try LocalImportParser.youtubePlaylistData(
            ["contents": [
                ["playlistVideoRenderer": [
                    "videoId": "jNQXAC9IVRw",
                    "title": ["simpleText": "Provider position seven"],
                    "isPlayable": true,
                    "index": ["simpleText": "7"],
                ]],
                ["playlistVideoRenderer": [
                    "videoId": "9bZkp7q19f0",
                    "title": ["simpleText": "Provider position nine"],
                    "isPlayable": true,
                    "index": ["simpleText": "9"],
                ]],
            ]],
            expectedPlaylistID: playlistID
        )

        let skippedPositions = Set(page.skippedItems.map(\.position))
        XCTAssertEqual(page.items.map(\.playlistPosition), [7, 9])
        let reconstructedPositions = LocalImportYouTubePlaylistPositionPolicy.positions(
            for: page.items,
            skippedPositions: skippedPositions
        )

        XCTAssertEqual(reconstructedPositions, [7, 9])
    }

    func testYouTubePlaylistSyntheticMoreRowUsesProviderPositionWhenContinuationRemains() throws {
        let playlistID = "PL1234567890abcdefghijklmnop"
        let firstPage = try LocalImportParser.youtubePlaylistData(
            [
                "contents": [
                    ["playlistVideoRenderer": [
                        "videoId": "jNQXAC9IVRw",
                        "title": ["simpleText": "Provider position seven"],
                        "isPlayable": true,
                        "index": ["simpleText": "7"],
                    ]],
                    ["continuationItemRenderer": [
                        "continuationEndpoint": [
                            "continuationCommand": ["token": "continuation-token"],
                        ],
                    ]],
                ],
            ],
            expectedPlaylistID: playlistID
        )

        XCTAssertEqual(firstPage.continuation, "continuation-token")
        XCTAssertEqual(firstPage.items.map(\.playlistPosition), [7])

        let offset = max(
            firstPage.nextPosition - 1,
            firstPage.items.count + firstPage.skippedItems.count
        )
        let syntheticPosition = LocalImportYouTubePlaylistLimitPolicy.syntheticMoreItemsPosition(
            offset: offset,
            items: firstPage.items,
            skippedItems: firstPage.skippedItems
        )
        XCTAssertEqual(offset, 7)
        XCTAssertEqual(syntheticPosition, 8)
        XCTAssertGreaterThan(syntheticPosition, try XCTUnwrap(firstPage.items.first?.playlistPosition))
    }

    func testYouTubePlaylistSyntheticMoreRowDoesNotReuseProviderPosition() throws {
        let playlistID = "PL1234567890abcdefghijklmnop"
        let firstPage = try LocalImportParser.youtubePlaylistData(
            [
                "contents": [
                    ["lockupViewModel": [
                        "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                        "metadata": [
                            "lockupMetadataViewModel": [
                                "title": ["content": "Unavailable row"],
                            ],
                        ],
                    ]],
                    ["playlistVideoRenderer": [
                        "videoId": "jNQXAC9IVRw",
                        "title": ["simpleText": "Provider position three"],
                        "isPlayable": true,
                        "index": ["simpleText": "3"],
                    ]],
                    ["continuationItemRenderer": [
                        "continuationEndpoint": [
                            "continuationCommand": ["token": "continuation-token"],
                        ],
                    ]],
                ],
            ],
            expectedPlaylistID: playlistID
        )

        XCTAssertEqual(firstPage.items.map(\.playlistPosition), [3])
        XCTAssertEqual(firstPage.skippedItems.map(\.position), [1])
        let countBasedPosition = firstPage.items.count + firstPage.skippedItems.count + 1
        XCTAssertEqual(countBasedPosition, 3)

        let offset = max(
            firstPage.nextPosition - 1,
            firstPage.items.count + firstPage.skippedItems.count
        )
        let syntheticPosition = LocalImportYouTubePlaylistLimitPolicy.syntheticMoreItemsPosition(
            offset: offset,
            items: firstPage.items,
            skippedItems: firstPage.skippedItems
        )
        XCTAssertEqual(syntheticPosition, 4)
        XCTAssertNotEqual(syntheticPosition, try XCTUnwrap(firstPage.items.first?.playlistPosition))
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

    func testPlaylistSelectionTogglesRepeatedTrackOccurrencesIndependently() {
        let first = playlistItem(position: 1, trackID: "repeated-track")
        let second = playlistItem(position: 2, trackID: "repeated-track")
        let playlist = LocalImportPlaylist(
            playlistID: "playlist",
            title: "Playlist",
            author: "Artist",
            artworkURL: nil,
            sourceURL: "https://www.youtube.com/playlist?list=playlist",
            items: [first, second],
            skippedItems: []
        )

        var selectedItemIDs = LocalImportPlaylistSelectionPolicy.allItemIDs(in: playlist.items)
        selectedItemIDs = LocalImportPlaylistSelectionPolicy.toggledItemIDs(
            selectedItemIDs,
            item: first
        )

        XCTAssertEqual(
            LocalImportPlaylistSelectionPolicy.selectedItems(in: playlist, itemIDs: selectedItemIDs)
                .map(\.id),
            [second.id]
        )
        XCTAssertEqual(
            LocalImportPlaylistDownloadPolicy.uniqueItems([first, second]).map(\.position),
            [1]
        )
    }

    private func playlistItem(position: Int, trackID: String) -> LocalImportPlaylistItem {
        let sourceURL = "https://www.youtube.com/watch?v=video\(position)"
        let track = LocalImportSpotifyTrack(
            provider: "youtube",
            type: "track",
            trackID: trackID,
            title: "Song \(position)",
            artist: "Artist",
            album: nil,
            trackNumber: position,
            durationSeconds: 180,
            artworkURL: nil,
            embedURL: "",
            sourceURL: sourceURL
        )
        let candidate = LocalImportAudioSourceMatch(
            videoID: "video\(position)",
            playlistPosition: nil,
            title: "Song \(position)",
            artist: "Artist",
            album: nil,
            durationSeconds: 180,
            thumbnailURL: nil,
            sourceProvider: .youtube,
            officialArtist: false,
            sourceURL: sourceURL,
            score: 1,
            confidence: "high",
            match: .init(
                title: 1,
                artist: 1,
                album: nil,
                duration: 1,
                durationDeltaSeconds: 0
            )
        )
        return LocalImportPlaylistItem(position: position, track: track, candidate: candidate)
    }
}
