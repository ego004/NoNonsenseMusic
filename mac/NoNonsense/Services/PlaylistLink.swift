import Foundation

/// A playlist's link (8 Oct). What you share is the web address, `<server>/p/<id>`: chat apps make it clickable, and
/// the server's page there hands over to `nononsense://playlist/<id>`, which macOS opens in this app (Info.plist,
/// CFBundleURLTypes). Opening one shows the playlist if you may see it: public, or shared with you.
enum PlaylistLink {
    /// The address to share.
    static func web(_ id: UUID) -> URL {
        API.baseURL.appending(path: "p").appending(path: id.uuidString.lowercased())
    }

    /// The playlist a link names: `nononsense://playlist/<id>`, or the web address itself.
    static func playlistID(in url: URL) -> UUID? {
        let parts = url.scheme == "nononsense" ? [url.host() ?? ""] + url.pathComponents.filter { $0 != "/" }
                                                : url.pathComponents.filter { $0 != "/" }
        guard let i = parts.firstIndex(where: { $0 == "playlist" || $0 == "p" }), i + 1 < parts.count else { return nil }
        return UUID(uuidString: parts[i + 1])
    }
}
