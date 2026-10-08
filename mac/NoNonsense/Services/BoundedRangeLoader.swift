import AVFoundation
import UniformTypeIdentifiers

/// YouTube audio for Apple's player, fetched in bounded ranges (8 Oct, TICKETS 0a). Apple's player asks for a file
/// open-ended (`bytes=0-`), and YouTube sends that at about playback speed: 0.87–2 s from a link to the first sound
/// (measured 8 Oct, NN_SELFTEST_LATENCY), where a bounded 256 KB range takes ~70 ms. So the player gets a private
/// address (`nnyt://…`) and this delegate answers its byte requests from the song's AudioDownload, which fetches the
/// real link in ranges of at most 1 MB, the first one small, and keeps the whole file in the cache once it is in
/// (TICKETS 0b). Measured 8 Oct: this does not start a song sooner (the player starts on YouTube's first burst, which is
/// not throttled); it keeps the rest of the song and seeks at full speed, and it is what fills the cache.
/// Every copy plays through it (JioSaavn too: so it is cached). The player is told the audio is AAC in MP4.
nonisolated final class BoundedRangeLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = BoundedRangeLoader()
    static let scheme = "nnyt"
    static let firstRange = 256 * 1024                // the first answer: small, so the player can start at once
    static let range = 1024 * 1024                    // then 1 MB at a time

    private let queue = DispatchQueue(label: "app.nononsense.bounded-range-loader")
    // touched on `queue` only
    private var songs: [String: (link: URL, key: String)] = [:]   // the private address's id → the song's link and key
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// An asset for Apple's player that plays `url` through this loader.
    func asset(for url: URL, key: String) -> AVURLAsset {
        let id = UUID().uuidString
        queue.sync { songs[id] = (url, key) }
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://audio/\(id).m4a")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let address = loadingRequest.request.url, address.scheme == Self.scheme else { return false }
        let id = address.deletingPathExtension().lastPathComponent
        guard let song = songs[id] else { return false }
        let request = Request(loadingRequest)
        let key = ObjectIdentifier(loadingRequest)
        running[key] = Task { [weak self] in
            await self?.serve(request, from: AudioDownloads.shared.download(song.key, link: song.link))
            self?.queue.async { self?.running[key] = nil }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        running.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    /// AVFoundation's request, carried into the task that answers it (it is answered from one place at a time).
    private struct Request: @unchecked Sendable {
        let r: AVAssetResourceLoadingRequest
        init(_ r: AVAssetResourceLoadingRequest) { self.r = r }
    }

    private func serve(_ request: Request, from download: AudioDownload) async {
        let r = request.r
        do {
            let length = try await download.totalLength()
            if let info = r.contentInformationRequest {
                info.contentType = UTType.mpeg4Audio.identifier
                info.contentLength = Int64(length)
                info.isByteRangeAccessSupported = true
            }
            guard let data = r.dataRequest else { r.finishLoading(); return }
            var at = Int(data.currentOffset != 0 ? data.currentOffset : data.requestedOffset)
            let end = data.requestsAllDataToEndOfResource || data.requestedLength == 0
                ? length : min(length, Int(data.requestedOffset) + data.requestedLength)
            while at < end, !Task.isCancelled {
                let piece = try await download.bytes(at, min(at + Self.range, end) - 1)
                if piece.isEmpty { break }
                data.respond(with: piece)
                at += piece.count
            }
            if !Task.isCancelled { r.finishLoading() }
        } catch {
            if !Task.isCancelled { r.finishLoading(with: error) }
        }
    }
}
