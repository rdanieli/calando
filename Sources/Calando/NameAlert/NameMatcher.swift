import Foundation

enum NameMatcher {
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter }
            .map(String.init)
    }

    static func parseNames(_ raw: String) -> [String] {
        var seen: Set<[String]> = []
        var names: [String] = []
        for piece in raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }) {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            let key = tokens(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            names.append(trimmed)
        }
        return names
    }

    static func triggers(names: [String], variants: [String]) -> [[String]] {
        var seen: Set<[String]> = []
        return (names + variants).map(tokens).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func firstTrigger(in text: String, triggers: [[String]]) -> String? {
        let words = tokens(text)
        guard !words.isEmpty else { return nil }
        var best: (position: Int, trigger: [String])?
        for trigger in triggers where trigger.count <= words.count {
            var start = 0
            while start + trigger.count <= words.count {
                if Array(words[start..<start + trigger.count]) == trigger {
                    if best == nil || start < best!.position {
                        best = (start, trigger)
                    }
                    break
                }
                start += 1
            }
        }
        return best?.trigger.joined(separator: " ")
    }
}
