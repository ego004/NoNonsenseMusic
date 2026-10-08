import AVFoundation
import UniformTypeIdentifiers

/// YouTube audio for Apple's player, fetched in bounded ranges (8 Oct, TICKETS 0a). Apple's player asks for a file
/// open-ended (`bytes=0-`), and YouTube sends that at about playback speed: 0.87–2 s from a link to the first sound
/// (measured 8 Oct, NN_SELFTEST_LATENCY), where a bounded 256 KB range takes ~70 ms. So the player gets a private
/// address (`nnyt://…`) and this delegate answers its byte requests by fetching the real link in ranges of at most
/// 1 MB, the first one small, so sound starts as soon as the first range is in.
/// Any link works (the self-test serves a local file); the player is told the audio is AAC in MP4 (YouTube's itag 140).
nonisolated final class BoundedRangeLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = BoundedRangeLoader()
    static let scheme = "nnyt"
    static let firstRange = 256 * 1024                // the first answer: small, so the player can start at once
    static let range = 1024 * 1024                    // then 1 MB at a time

    private let queue = DispatchQueue(label: "app.nononsense.bounded-range-loader")
    private let session = URLSession(configuration: .ephemeral)
    // touched on `queue` only
    private var links: [String: URL] = [:]            // the private address's id → the real link
    private var lengths: [String: Int] = [:]
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// An asset for Apple's player that plays `url` through this loader.
    func asset(for url: URL) -> AVURLAsset {
        let id = UUID().uuidString
        queue.sync { links[id] = url }
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://audio/\(id).m4a")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let address = loadingRequest.request.url, address.scheme == Self.scheme else { return false }
        let id = address.deletingPathExtension().lastPathComponent
        guard let link = links[id] else { return false }
        let request = Request(loadingRequest)
        let key = ObjectIdentifier(loadingRequest)
        running[key] = Task { [weak self] in
            await self?.serve(request, id: id, from: link)
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

    private func serve(_ request: Request, id: String, from link: URL) async {
        let r = request.r
        do {
            var length = queue.sync { lengths[id] }
            if let info = r.contentInformationRequest {
                // YouTube's links say the length (`clen`); anything else is asked with one tiny range
                if length == nil { length = try await Self.declaredLength(link) ?? fetch(link, from: 0, to: 0).total }
                queue.sync { lengths[id] = length }
                info.contentType = UTType.mpeg4Audio.identifier
                info.contentLength = Int64(length ?? 0)
                info.isByteRangeAccessSupported = true
            }
            guard let data = r.dataRequest else { r.finishLoading(); return }
            var at = Int(data.currentOffset != 0 ? data.currentOffset : data.requestedOffset)
            let end = data.requestsAllDataToEndOfResource || data.requestedLength == 0
                ? (length ?? Int.max) : Int(data.requestedOffset) + data.requestedLength
            var first = true
            while at < end, !Task.isCancelled {
                let size = first ? Self.firstRange : Self.range
                let piece = try await fetch(link, from: at, to: min(at + size, end) - 1)
                if length == nil, let total = piece.total { length = total; queue.sync { lengths[id] = total } }
                if piece.data.isEmpty { break }
                data.respond(with: piece.data)
                at += piece.data.count
                first = false
                if let length, at >= length { break }
            }
            if !Task.isCancelled { r.finishLoading() }
        } catch {
            if !Task.isCancelled { r.finishLoading(with: error) }
        }
    }

    /// One bounded range: bytes `from` to `to`, both included. `total`: the whole file's length, from Content-Range.
    private func fetch(_ link: URL, from: Int, to: Int) async throws -> (data: Data, total: Int?) {
        var request = URLRequest(url: link, timeoutInterval: 15)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard let status = http?.statusCode, status == 206 || status == 200 else {
            throw URLError(.badServerResponse)
        }
        let total = (http?.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last).flatMap { Int($0) }
        return (data, total)
    }

    private static func declaredLength(_ link: URL) -> Int? {
        URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "clen" }?.value.flatMap(Int.init)
    }
}
