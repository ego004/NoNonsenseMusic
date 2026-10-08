import Foundation

/// YouTube audio links asked for by this Mac itself (8 Oct), not by the server. A YouTube link carries the IP address
/// that asked for it, signed (`ip` is in its `sparams`): a link the server fetched plays only on the server's own
/// network. Asked from here, it is this Mac's, so a server anywhere (a host on the web) still plays YouTube songs, and
/// the server does no YouTube lookups for you. The server's /play stays the fallback (API.audioURL).
///
/// How, tested 8 Oct on three songs (two music tracks, one video): one anonymous visitor id from YouTube's home page,
/// then one request to its player API as YouTube's visionOS app, the client yt-dlp itself uses (no JavaScript, no PO
/// token). Whole songs downloaded with AVPlayer's own User-Agent; ~0.8 s for both requests, ~0.35 s once the visitor
/// id is known. The Android client gave only the first 1 MB of music tracks (403 after), so not that one.
/// No cookies are kept and nothing is written to disk (an ephemeral session); the visitor id lives in memory while the
/// app runs. When YouTube changes this client, update `client` from yt-dlp's `_base.py` ('visionos').
actor YouTubeLookup {
    static let shared = YouTubeLookup()

    enum Failure: Error { case notPlayable(String), noAudio, noVisitorID }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let client: [String: String] = [
        "clientName": "VISIONOS", "clientVersion": "1.02", "deviceMake": "Apple", "deviceModel": "RealityDevice17,1",
        "userAgent": userAgent, "osName": "visionOS", "osVersion": "26.5.23O471", "hl": "en",
    ]
    /// itag 140: AAC in an MP4 file, the audio AVPlayer plays (YouTube's default Opus in WebM it cannot)
    private static let aacItag = 140

    private let session = URLSession(configuration: .ephemeral)
    private var visitorID: String?
    /// video id → its link, until a few minutes before the link's own `expire`
    private var links: [String: (url: URL, until: Date)] = [:]

    /// The audio link for a YouTube video id; `fresh` skips the remembered one (it failed to play).
    func audioURL(videoID: String, fresh: Bool = false) async throws -> URL {
        if !fresh, let known = links[videoID], known.until > .now { return known.url }
        do {
            return try await lookUp(videoID)
        } catch Failure.notPlayable("LOGIN_REQUIRED") where visitorID != nil {
            visitorID = nil                                  // the visitor id went stale: one more try with a new one
            return try await lookUp(videoID)
        }
    }

    /// A link that failed to play: the next ask looks it up again.
    func forget(_ videoID: String) { links[videoID] = nil }

    /// Looks up the next songs ahead of time (the queue, the top search result), one at a time, skipping known ones.
    func warm(_ videoIDs: [String]) async {
        for id in videoIDs where links[id].map({ $0.until <= .now }) ?? true {
            _ = try? await audioURL(videoID: id)
        }
    }

    private func lookUp(_ videoID: String) async throws -> URL {
        let visitor = try await currentVisitorID()
        var client: [String: Any] = Self.client
        client["visitorData"] = visitor
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        request.setValue("101", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("1.02", forHTTPHeaderField: "X-Youtube-Client-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": client], "videoId": videoID, "contentCheckOk": true, "racyCheckOk": true,
        ])
        let (data, _) = try await session.data(for: request)
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let status = (reply["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "no status"
        guard status == "OK" else { throw Failure.notPlayable(status) }
        let formats = (reply["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]] ?? []
        guard let link = formats.first(where: { $0["itag"] as? Int == Self.aacItag })?["url"] as? String,
              let url = URL(string: link) else { throw Failure.noAudio }
        links[videoID] = (url, Self.usableUntil(url))
        return url
    }

    private func currentVisitorID() async throws -> String {
        if let visitorID { return visitorID }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/")!, timeoutInterval: 10)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let page = String(decoding: data, as: UTF8.self)
        guard let start = page.range(of: "\"VISITOR_DATA\":\"")?.upperBound,
              let end = page[start...].firstIndex(of: "\"") else { throw Failure.noVisitorID }
        visitorID = String(page[start..<end])
        return visitorID!
    }

    /// 10 minutes before the link's own `expire` (seconds since 1970); 1 hour when it has none.
    private static func usableUntil(_ url: URL) -> Date {
        let expire = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "expire" }?.value.flatMap(TimeInterval.init)
        return expire.map { Date(timeIntervalSince1970: $0 - 600) } ?? .now.addingTimeInterval(3600)
    }
}
