import AppKit

/// Learns the names you correct right after dictating them.
///
/// After a paste, it follows the text box (through Accessibility) for up to a minute. When you move on (send the
/// message, change field or app), it compares what was pasted with what you left, and picks up words whose spelling
/// you fixed: "wisper" → "Wispr". Only names and unusual words count; fixing a typo in a common word doesn't.
/// Nothing is saved except the learned word.
final class WordLearner {
    /// New words to add to the dictionary.
    var onLearn: (([String]) -> Void)?
    /// Whether a word is already in the dictionary.
    var isKnown: (String) -> Bool = { _ in false }

    private struct Watch {
        let element: AXUIElement
        let pasted: String
        let prefix: String
        let suffix: String
        let started: Date
        var lastSeen: String
    }

    private var watch: Watch?
    private var timer: Timer?
    private var startWork: DispatchWorkItem?

    /// Call right after `text` was pasted into another app.
    func pasted(_ text: String) {
        finish()
        let pasted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty, pasted.count < 4000, !NSApp.isActive else { return }
        // Give the app a moment to show the pasted text.
        let work = DispatchWorkItem { [weak self] in self?.begin(pasted) }
        startWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Ends the current watch (for example, a new dictation started) and learns from what it saw.
    func finish() {
        startWork?.cancel()
        startWork = nil
        timer?.invalidate()
        timer = nil
        guard let w = watch else { return }
        watch = nil
        guard w.lastSeen != w.pasted else { return }
        let words = Self.corrections(from: w.pasted, to: w.lastSeen).filter { !isKnown($0) }
        if !words.isEmpty { onLearn?(words) }
    }

    private func begin(_ pasted: String) {
        guard !NSApp.isActive, let element = AX.focusedElement(), let value = AX.value(of: element), value.count < 300_000,
              let range = value.range(of: pasted, options: .backwards) else { return }
        watch = Watch(element: element, pasted: pasted,
                      prefix: String(value[..<range.lowerBound].suffix(40)),
                      suffix: String(value[range.upperBound...].prefix(40)),
                      started: Date(), lastSeen: pasted)
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard var w = watch else { return finish() }
        // In Murmur's own window, Accessibility calls into Murmur itself would stall the main thread.
        guard !NSApp.isActive, Date().timeIntervalSince(w.started) < 60,
              let focused = AX.focusedElement(), CFEqual(focused, w.element),
              let value = AX.value(of: focused),
              let region = Self.region(in: value, prefix: w.prefix, suffix: w.suffix)
        else { return finish() } // moved on, sent the message, or too much changed to follow
        w.lastSeen = region
        watch = w
    }

    /// The part of the text box between the text that surrounded the paste.
    static func region(in value: String, prefix: String, suffix: String) -> String? {
        var start = value.startIndex
        if !prefix.isEmpty {
            guard let r = value.range(of: prefix, options: .backwards) else { return nil }
            start = r.upperBound
        }
        var end = value.endIndex
        if !suffix.isEmpty {
            guard let r = value.range(of: suffix, range: start..<value.endIndex) else { return nil }
            end = r.lowerBound
        }
        let region = value[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return region.isEmpty ? nil : region
    }

    // MARK: Comparing

    /// Words or short phrases whose spelling changed from `before` to `after` and look like names or terms.
    static func corrections(from before: String, to after: String) -> [String] {
        let a = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = after.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !a.isEmpty, !b.isEmpty, a.count <= 600, b.count <= 800 else { return [] }

        // Token-level edit distance. A substitution costs 1 only when the two words look alike (a spelling fix);
        // otherwise it costs as much as deleting one and inserting the other, so rewrites aren't taken for fixes.
        let n = a.count, m = b.count
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let sub = core(a[i - 1]) == core(b[j - 1]) ? 0 : (alike(a[i - 1], b[j - 1]) ? 1 : 2)
                cost[i][j] = min(cost[i - 1][j - 1] + sub, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            }
        }

        // Walk back, collecting the indexes in `b` of words that replaced a similar word.
        var fixed: [Int] = []
        var i = n, j = m
        while i > 0, j > 0 {
            let same = core(a[i - 1]) == core(b[j - 1])
            let sub = same ? 0 : (alike(a[i - 1], b[j - 1]) ? 1 : 2)
            if cost[i][j] == cost[i - 1][j - 1] + sub, sub < 2 {
                if !same { fixed.append(j - 1) }
                i -= 1; j -= 1
            } else if cost[i][j] == cost[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        fixed.reverse()

        // Neighbouring fixes form one phrase ("wisper flow" → "Wispr Flow").
        var phrases: [[Int]] = []
        for index in fixed {
            if let last = phrases.last?.last, index == last + 1 { phrases[phrases.count - 1].append(index) } else { phrases.append([index]) }
        }
        var out: [String] = []
        for phrase in phrases where phrase.count <= 3 {
            let words = phrase.map { core(b[$0]) }
            guard words.allSatisfy({ $0.count >= 2 && $0.contains(where: \.isLetter) }) else { continue }
            let nameLike = phrase.contains { looksLikeName(b[$0], atSentenceStart: $0 == 0 || endsSentence(b[$0 - 1])) }
            guard nameLike else { continue }
            let text = words.joined(separator: " ")
            if !out.contains(text) { out.append(text) }
        }
        return Array(out.prefix(3))
    }

    /// The word without surrounding punctuation.
    static func core(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "@#+")))
    }

    private static func fold(_ word: String) -> String {
        core(word).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Same word with different capitals or accents, or a spelling within a few letters.
    static func alike(_ x: String, _ y: String) -> Bool {
        let a = fold(x), b = fold(y)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let distance = levenshtein(Array(a), Array(b))
        return Double(distance) / Double(max(a.count, b.count)) <= 0.5
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".!?:".contains(last)
    }

    /// Capitalized in the middle of a sentence, mixed case ("ChatGPT"), or not a word the spell checker knows.
    private static func looksLikeName(_ token: String, atSentenceStart: Bool) -> Bool {
        let word = core(token)
        guard let first = word.first else { return false }
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        if first.isUppercase, !atSentenceStart { return true }
        return !SpellCheck.knows(word)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// Whether a word is ordinary Spanish or English (then a correction is a typo fix, not a name to learn).
enum SpellCheck {
    private static let languages: [String] = {
        let available = NSSpellChecker.shared.availableLanguages
        return ["es", "en"].compactMap { code in available.first { $0 == code || $0.hasPrefix(code + "_") } }
    }()

    static func knows(_ word: String) -> Bool {
        let lower = word.lowercased()
        for language in languages {
            let miss = NSSpellChecker.shared.checkSpelling(of: lower, startingAt: 0, language: language, wrap: false,
                                                           inSpellDocumentWithTag: 0, wordCount: nil)
            if miss.location == NSNotFound { return true }
        }
        return false
    }
}

/// Reading other apps' text fields through Accessibility, with a short timeout so a hung app can't stall Murmur.
enum AX {
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
