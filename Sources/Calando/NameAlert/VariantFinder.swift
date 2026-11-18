import Foundation

struct VariantSuggestion: Codable, Equatable, Identifiable {
    let word: String
    let name: String
    let occurrences: Int

    var id: String { word }
}

enum VariantFinder {
    static let minimumOccurrences = 2
    static let minimumLength = 3

    static func editDistance(_ left: String, _ right: String) -> Int {
        let a = Array(left), b = Array(right)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            previous = current
        }
        return previous[b.count]
    }

    static func candidates(heard: String, said: String, name: String) -> [String] {
        let target = NameMatcher.tokens(name).joined()
        guard !target.isEmpty else { return [] }
        let carrierWords = Set(NameMatcher.tokens(said)).subtracting(NameMatcher.tokens(name))
        let tolerance = max(1, target.count / 2)
        var seen: Set<String> = []
        return NameMatcher.tokens(heard).filter { word in
            word != target
                && word.count >= minimumLength
                && !carrierWords.contains(word)
                && editDistance(word, target) <= tolerance
                && seen.insert(word).inserted
        }
    }

    static func suggestions(from tallies: [String: [String: Int]]) -> [VariantSuggestion] {
        var best: [String: VariantSuggestion] = [:]
        for (name, counts) in tallies {
            for (word, occurrences) in counts where occurrences >= minimumOccurrences {
                if let existing = best[word], existing.occurrences >= occurrences { continue }
                best[word] = VariantSuggestion(word: word, name: name, occurrences: occurrences)
            }
        }
        return best.values.sorted { first, second in
            first.occurrences == second.occurrences ? first.word < second.word : first.occurrences > second.occurrences
        }
    }
}
