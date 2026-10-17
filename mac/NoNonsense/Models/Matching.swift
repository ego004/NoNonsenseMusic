import Foundation

/// The search's word rule, as the server has it (backend services/matching.py: normalise, found, words_of), for a search
/// without the server: the songs you have that it finds are the ones the server would (#26). Foundation has NFKD and
/// the combining classes, so a title reads here exactly as there.
enum Matching {
    /// A typed word this long or longer also matches a word this alike: a ratio from 0 to 100, rapidfuzz's (the
    /// server's TYPO_MIN_LENGTH and TYPO_SIMILARITY, #25). Shorter words must be as typed.
    static let typoMinLength = 4, typoSimilarity = 85

    /// `text` as the server compares it: lower case, NFKD, every mark of a nonzero combining class dropped, anything
    /// else that is not a letter or a digit a space, single spaces.
    static func normalise(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.lowercased().decomposedStringWithCompatibilityMapping.unicodeScalars
        where scalar.properties.canonicalCombiningClass == .notReordered {
            kept.append(isLetterOrDigit(scalar) ? scalar : " ")
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// The words `found` looks among: a title's and its artists' (or any names'), normalised, each once.
    static func words(of names: [String]) -> Set<String> {
        Set(normalise(names.joined(separator: " ")).split(separator: " ").map(String.init))
    }

    /// Whether a typed word is among `have`: as typed, or, for `typoMinLength` letters or more, as a word
    /// `typoSimilarity` alike.
    static func found(_ word: String, in have: Set<String>) -> Bool {
        have.contains(word) || (word.unicodeScalars.count >= typoMinLength && have.contains { alike(word, $0) })
    }

    /// The songs among `mine` that a search for `query` finds as yours, each once, in the order given: those with a copy
    /// that holds every typed word as `found` takes it (the server's library.matching_songs).
    static func songs(matching query: String, in mine: [Track]) -> [Track] {
        let typed = Set(normalise(query).split(separator: " ").map(String.init))
        guard !typed.isEmpty else { return [] }
        var songs: [Track] = []
        var listed: Set<String> = []        // the copies of the songs found: a song in Downloads and Liked Songs is listed once
        for song in mine where !song.listings.contains(where: { listed.contains($0.key) }) {
            let holds = song.listings.contains { copy in
                let have = words(of: [copy.title] + copy.artists)
                return typed.allSatisfy { found($0, in: have) }
            }
            if holds {
                songs.append(song)
                listed.formUnion(song.listings.map(\.key))
            }
        }
        return songs
    }

    /// Python's isalnum: a letter of any kind or a number of any kind.
    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    /// rapidfuzz's ratio of two words is at least `typoSimilarity`: 200 times their longest common subsequence over
    /// both lengths, in whole numbers (the server's floats agree, 85.0 included).
    private static func alike(_ a: String, _ b: String) -> Bool {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        let both = x.count + y.count
        guard 200 * min(x.count, y.count) >= typoSimilarity * both else { return false }   // lengths too far apart
        var previous = [Int](repeating: 0, count: y.count + 1)
        for c in x {
            var row = [Int](repeating: 0, count: y.count + 1)
            for j in y.indices { row[j + 1] = c == y[j] ? previous[j] + 1 : max(previous[j + 1], row[j]) }
            previous = row
        }
        return 200 * previous[y.count] >= typoSimilarity * both
    }
}
