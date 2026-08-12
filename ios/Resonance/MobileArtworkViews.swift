import SwiftUI
import UIKit

struct AppBackground: View {
    @Environment(\.resonancePalette) private var palette

    var body: some View {
        palette.background.ignoresSafeArea()
    }
}

private struct SquareArtworkContainer<Content: View>: View {
    let content: (CGSize) -> Content

    init(@ViewBuilder content: @escaping (CGSize) -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            content(geometry.size)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct ArtworkTile: View {
    let symbol: String

    var body: some View {
        SquareArtworkContainer { _ in
            ArtworkPlaceholder(symbol: symbol)
        }
    }
}

private struct ArtworkPlaceholder: View {
    @Environment(\.resonancePalette) private var palette
    let symbol: String
    var compact = false

    var body: some View {
        ZStack {
            palette.secondary
            Image(systemName: symbol)
                .font(compact ? .caption.weight(.semibold) : .title2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

struct PlaylistArtworkTile: View {
    let playlist: MobilePlaylist
    let tracksByID: [UUID: MobileTrack]

    private var artworkTracks: [MobileTrack?] {
        let trackIDs = playlist.automaticArtworkTrackIDs
        return (0..<4).map { index in
            guard trackIDs.indices.contains(index) else { return nil }
            return tracksByID[trackIDs[index]]
        }
    }

    var body: some View {
        if playlist.isSystem || playlist.automaticArtworkTrackIDs.isEmpty {
            ArtworkTile(symbol: playlist.isSystem ? "heart.fill" : "music.note.list")
        } else {
            let tracks = artworkTracks
            SquareArtworkContainer { size in
                let cellSize = CGSize(width: size.width / 2, height: size.height / 2)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        artworkCell(tracks[0], size: cellSize)
                        artworkCell(tracks[1], size: cellSize)
                    }
                    HStack(spacing: 0) {
                        artworkCell(tracks[2], size: cellSize)
                        artworkCell(tracks[3], size: cellSize)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func artworkCell(_ track: MobileTrack?, size: CGSize) -> some View {
        if let track {
            TrackArtwork(track: track)
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            ArtworkPlaceholder(symbol: "music.note", compact: true)
                .frame(width: size.width, height: size.height)
                .clipped()
        }
    }
}

struct TrackArtwork: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: MobileTrack
    var fallbackSymbol = "music.note"
    @State private var loadedArtwork: LoadedArtwork?

    private struct LoadedArtwork {
        let identity: String
        let image: UIImage
    }

    private var loadIdentity: String {
        "\(track.id.uuidString)|\(track.artworkFilename ?? "none")|\(library.artworkVersion(for: track))"
    }

    private var displayedArtwork: UIImage? {
        if let cached = library.cachedArtwork(for: track) { return cached }
        guard loadedArtwork?.identity == loadIdentity else { return nil }
        return loadedArtwork?.image
    }

    var body: some View {
        SquareArtworkContainer { size in
            if let artwork = displayedArtwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
            } else {
                ArtworkTile(symbol: fallbackSymbol)
            }
        }
        .task(id: loadIdentity) {
            loadedArtwork = nil
            guard track.artworkFilename != nil else { return }
            let identity = loadIdentity
            let image = await library.loadArtwork(for: track)
            guard !Task.isCancelled, let image else { return }
            loadedArtwork = LoadedArtwork(identity: identity, image: image)
        }
    }
}

struct ServerArtwork: View {
    let song: MobileRemoteSong

    var body: some View {
        SquareArtworkContainer { size in
            if song.isMetadataLoading {
                ZStack {
                    ArtworkTile(symbol: "music.note")
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.72))
                }
            } else if let artworkURL = song.artworkURL {
                AsyncImage(url: artworkURL, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipped()
                    case .empty:
                        ZStack {
                            ArtworkTile(symbol: "music.note")
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                    case .failure:
                        ArtworkTile(symbol: "music.note")
                    @unknown default:
                        ArtworkTile(symbol: "music.note")
                    }
                }
            } else {
                ArtworkTile(symbol: "music.note")
            }
        }
        .accessibilityHidden(true)
    }
}
