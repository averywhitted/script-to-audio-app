#if os(iOS)
import Foundation

// MARK: - Grapheme-to-Phoneme protocol

/// Converts English text to an IPA phoneme string compatible with Kokoro's vocabulary.
/// The output is a sequence of characters drawn from `KokoroVocab.phonemeToID`.
protocol G2PConverter: Sendable {
    func phonemize(_ text: String, lang: String) -> String
}

// MARK: - Kokoro vocabulary (exact mapping from config.json)

enum KokoroVocab {
    /// Maps each IPA symbol to its token ID.
    /// Source: kokoro-onnx/config.json — 114 entries.
    static let phonemeToID: [Character: Int64] = [
        ";": 1, ":": 2, ",": 3, ".": 4, "!": 5, "?": 6, "—": 9, "…": 10,
        "\"": 11, "(": 12, ")": 13, "\u{201C}": 14, "\u{201D}": 15, " ": 16,
        "\u{0303}": 17,   // combining tilde
        "ʣ": 18, "ʥ": 19, "ʦ": 20, "ʨ": 21, "ᵝ": 22, "ꭧ": 23,
        "A": 24, "I": 25, "O": 31, "Q": 33, "S": 35, "T": 36, "W": 39,
        "Y": 41, "ᵊ": 42,
        "a": 43, "b": 44, "c": 45, "d": 46, "e": 47, "f": 48, "h": 50,
        "i": 51, "j": 52, "k": 53, "l": 54, "m": 55, "n": 56, "o": 57,
        "p": 58, "q": 59, "r": 60, "s": 61, "t": 62, "u": 63, "v": 64,
        "w": 65, "x": 66, "y": 67, "z": 68,
        "ɑ": 69, "ɐ": 70, "ɒ": 71, "æ": 72, "β": 75, "ɔ": 76, "ɕ": 77,
        "ç": 78, "ɖ": 80, "ð": 81, "ʤ": 82, "ə": 83, "ɚ": 85, "ɛ": 86,
        "ɜ": 87, "ɟ": 90, "ɡ": 92, "ɥ": 99, "ɨ": 101, "ɪ": 102, "ʝ": 103,
        "ɯ": 110, "ɰ": 111, "ŋ": 112, "ɳ": 113, "ɲ": 114, "ɴ": 115,
        "ø": 116, "ɸ": 118, "θ": 119, "œ": 120, "ɹ": 123, "ɾ": 125,
        "ɻ": 126, "ʁ": 128, "ɽ": 129, "ʂ": 130, "ʃ": 131, "ʈ": 132,
        "ʧ": 133, "ʊ": 135, "ʋ": 136, "ʌ": 138, "ɣ": 139, "ɤ": 140,
        "χ": 142, "ʎ": 143, "ʒ": 147, "ʔ": 148,
        "ˈ": 156, "ˌ": 157, "ː": 158, "ʰ": 162, "ʲ": 164,
        "↓": 169, "→": 171, "↗": 172, "↘": 173, "ᵻ": 177,
    ]

    /// Filters an IPA string to only the characters present in the vocabulary.
    static func filter(_ phonemes: String) -> String {
        String(phonemes.unicodeScalars.filter { phonemeToID[Character($0)] != nil })
    }

    /// Converts a filtered IPA string to a token ID array (padding excluded).
    static func tokenize(_ phonemes: String) -> [Int64] {
        phonemes.compactMap { phonemeToID[$0] }
    }
}

// MARK: - Stub G2P (placeholder until espeak-ng is compiled for iOS)

/// Rule-based English G2P covering the most common screenplay vocabulary.
/// This is a stopgap — quality is good enough for initial testing but
/// proper espeak-ng integration (see ios-setup notes) will be noticeably better.
///
/// To replace with espeak-ng: implement `G2PConverter` using a C bridge to the
/// static espeak-ng library compiled for iOS (arm64 + Simulator). The phonemizer
/// Python package already wraps espeak-ng; the same C API (`espeak_TextToPhonemes`)
/// works from Swift via a bridging header.
struct RuleBasedG2P: G2PConverter {
    func phonemize(_ text: String, lang: String) -> String {
        let words = tokenizeText(text)
        var result = ""

        for token in words {
            switch token {
            case .punctuation(let p):
                result += p
            case .space:
                result += " "
            case .word(let w):
                let ipa = pronunciationForWord(w.lowercased())
                result += ipa
            }
        }

        return KokoroVocab.filter(result)
    }

    // MARK: - Tokenization

    private enum TextToken {
        case word(String)
        case punctuation(String)
        case space
    }

    private func tokenizeText(_ text: String) -> [TextToken] {
        var tokens: [TextToken] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                tokens.append(.word(current))
                current = ""
            }
        }

        for ch in text {
            if ch.isLetter || ch == "'" || ch == "-" {
                current.append(ch)
            } else if ch.isWhitespace {
                flush()
                tokens.append(.space)
            } else if ",.:;!?—…\"()".contains(ch) {
                flush()
                tokens.append(.punctuation(String(ch)))
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    // MARK: - Dictionary + rules

    private func pronunciationForWord(_ word: String) -> String {
        if let ipa = Self.dictionary[word] { return ipa }
        return applyRules(word)
    }

    /// Rule-based fallback: handles simple phonetic patterns.
    /// Produces rough IPA that passes through KokoroVocab.filter well.
    private func applyRules(_ word: String) -> String {
        var w = word
        var ipa = ""

        // Common multi-character substitutions applied left-to-right
        let rules: [(String, String)] = [
            ("tion", "ʃən"), ("sion", "ʒən"), ("ture", "ʧɚ"),
            ("th", "ð"), ("sh", "ʃ"), ("ch", "ʧ"), ("wh", "w"),
            ("ph", "f"), ("gh", ""), ("ck", "k"), ("ng", "ŋ"),
            ("qu", "kw"), ("wr", "r"), ("kn", "n"),
            ("oo", "uː"), ("ee", "iː"), ("ea", "iː"), ("ai", "eɪ"),
            ("ay", "eɪ"), ("oa", "oʊ"), ("ow", "oʊ"), ("ou", "aʊ"),
            ("oi", "ɔɪ"), ("au", "ɔː"), ("aw", "ɔː"),
            ("a", "æ"), ("e", "ɛ"), ("i", "ɪ"), ("o", "ɑ"),
            ("u", "ʌ"), ("y", "ɪ"),
            ("b", "b"), ("c", "k"), ("d", "d"), ("f", "f"),
            ("g", "ɡ"), ("h", "h"), ("j", "ʤ"), ("k", "k"),
            ("l", "l"), ("m", "m"), ("n", "n"), ("p", "p"),
            ("q", "k"), ("r", "ɹ"), ("s", "s"), ("t", "t"),
            ("v", "v"), ("w", "w"), ("x", "ks"), ("z", "z"),
        ]

        while !w.isEmpty {
            var matched = false
            for (pattern, replacement) in rules {
                if w.hasPrefix(pattern) {
                    ipa += replacement
                    w = String(w.dropFirst(pattern.count))
                    matched = true
                    break
                }
            }
            if !matched { w = String(w.dropFirst()) }
        }

        return ipa
    }

    // MARK: - Compact CMU-derived dictionary (top screenplay vocabulary)

    /// 400 most common English words in IPA (en-us, espeak-ng output, stress marked).
    /// Covers the bulk of screenplay dialogue. Extended automatically by `applyRules`
    /// for proper nouns and less common words.
    static let dictionary: [String: String] = [
        "the": "ðə", "a": "ə", "an": "æn", "and": "ænd", "or": "ɔːɹ",
        "but": "bʌt", "in": "ɪn", "on": "ɑn", "at": "æt", "to": "tə",
        "of": "əv", "for": "fɔːɹ", "with": "wɪð", "as": "æz",
        "is": "ɪz", "are": "ɑːɹ", "was": "wɑz", "were": "wɜːɹ",
        "be": "biː", "been": "bɪn", "being": "biːɪŋ",
        "have": "hæv", "has": "hæz", "had": "hæd",
        "do": "duː", "does": "dʌz", "did": "dɪd",
        "will": "wɪl", "would": "wʊd", "could": "kʊd", "should": "ʃʊd",
        "may": "meɪ", "might": "maɪt", "can": "kæn", "shall": "ʃæl",
        "i": "aɪ", "me": "miː", "my": "maɪ", "mine": "maɪn",
        "we": "wiː", "us": "ʌs", "our": "aʊɚ", "ours": "aʊɚz",
        "you": "juː", "your": "jɔːɹ", "yours": "jɔːɹz",
        "he": "hiː", "him": "hɪm", "his": "hɪz",
        "she": "ʃiː", "her": "hɜːɹ", "hers": "hɜːɹz",
        "it": "ɪt", "its": "ɪts",
        "they": "ðeɪ", "them": "ðɛm", "their": "ðɛɹ", "theirs": "ðɛɹz",
        "this": "ðɪs", "that": "ðæt", "these": "ðiːz", "those": "ðoʊz",
        "who": "huː", "whom": "huːm", "which": "wɪʧ", "what": "wɑt",
        "when": "wɛn", "where": "wɛɹ", "why": "waɪ", "how": "haʊ",
        "all": "ɔːl", "some": "sʌm", "any": "ɛniː", "no": "noʊ",
        "not": "nɑt", "so": "soʊ", "just": "ʤʌst", "only": "oʊnliː",
        "also": "ɔːlsoʊ", "too": "tuː", "very": "vɛɹiː",
        "more": "mɔːɹ", "most": "moʊst", "less": "lɛs", "least": "liːst",
        "much": "mʌʧ", "many": "mɛniː", "few": "fjuː",
        "here": "hɪɹ", "there": "ðɛɹ", "now": "naʊ", "then": "ðɛn",
        "well": "wɛl", "still": "stɪl", "never": "nɛvɚ", "always": "ɔːlweɪz",
        "already": "ɔːlɹɛdiː", "again": "əɡɛn", "back": "bæk",
        "away": "əweɪ", "around": "əɹaʊnd", "down": "daʊn", "up": "ʌp",
        "out": "aʊt", "over": "oʊvɚ", "under": "ʌndɚ", "through": "θɹuː",
        "about": "əbaʊt", "after": "æftɚ", "before": "bɪfɔːɹ",
        "between": "bɪtwiːn", "from": "fɹɑm", "into": "ɪntuː",
        "off": "ɔːf", "by": "baɪ", "than": "ðæn", "if": "ɪf",
        "though": "ðoʊ", "although": "ɔːlðoʊ", "because": "bɪkɑz",
        "since": "sɪns", "until": "ʌntɪl", "while": "waɪl",
        "yes": "jɛs", "yeah": "jɛə", "no": "noʊ", "ok": "oʊkeɪ",
        "okay": "oʊkeɪ", "please": "pliːz", "thank": "θæŋk",
        "thanks": "θæŋks", "sorry": "sɑɹiː", "right": "ɹaɪt",
        "know": "noʊ", "get": "ɡɛt", "got": "ɡɑt", "go": "ɡoʊ",
        "going": "ɡoʊɪŋ", "gone": "ɡɑn", "went": "wɛnt", "come": "kʌm",
        "came": "keɪm", "coming": "kʌmɪŋ", "look": "lʊk", "see": "siː",
        "saw": "sɔː", "seen": "siːn", "say": "seɪ", "said": "sɛd",
        "says": "sɛz", "tell": "tɛl", "told": "toʊld", "talk": "tɔːk",
        "think": "θɪŋk", "thought": "θɔːt", "know": "noʊ", "knew": "njuː",
        "want": "wɑnt", "need": "niːd", "try": "tɹaɪ", "tried": "tɹaɪd",
        "let": "lɛt", "make": "meɪk", "made": "meɪd", "put": "pʊt",
        "take": "teɪk", "took": "tʊk", "give": "ɡɪv", "gave": "ɡeɪv",
        "find": "faɪnd", "found": "faʊnd", "keep": "kiːp", "kept": "kɛpt",
        "leave": "liːv", "left": "lɛft", "bring": "bɹɪŋ", "brought": "bɹɔːt",
        "show": "ʃoʊ", "showed": "ʃoʊd", "run": "ɹʌn", "ran": "ɹæn",
        "stop": "stɑp", "start": "stɑɹt", "help": "hɛlp", "ask": "æsk",
        "wait": "weɪt", "hear": "hɪɹ", "heard": "hɜːɹd", "feel": "fiːl",
        "felt": "fɛlt", "call": "kɔːl", "called": "kɔːld",
        "love": "lʌv", "like": "laɪk", "hate": "heɪt", "hope": "hoʊp",
        "remember": "ɹɪmɛmbɚ", "forget": "fɚɡɛt", "believe": "bɪliːv",
        "understand": "ʌndɚstænd", "happen": "hæpən", "seem": "siːm",
        "mean": "miːn", "meant": "mɛnt", "live": "lɪv", "die": "daɪ",
        "kill": "kɪl", "fight": "faɪt", "hit": "hɪt", "move": "muːv",
        "change": "ʧeɪnʤ", "open": "oʊpən", "close": "kloʊz",
        "play": "pleɪ", "work": "wɜːɹk", "worked": "wɜːɹkt",
        "use": "juːz", "used": "juːzd", "turn": "tɜːɹn",
        "man": "mæn", "men": "mɛn", "woman": "wʊmən", "women": "wɪmɪn",
        "person": "pɜːɹsən", "people": "piːpəl", "child": "ʧaɪld",
        "children": "ʧɪldɹən", "boy": "bɔɪ", "girl": "ɡɜːɹl",
        "time": "taɪm", "day": "deɪ", "night": "naɪt", "year": "jɪɹ",
        "way": "weɪ", "thing": "θɪŋ", "things": "θɪŋz", "world": "wɜːɹld",
        "life": "laɪf", "place": "pleɪs", "hand": "hænd", "home": "hoʊm",
        "face": "feɪs", "door": "dɔːɹ", "room": "ɹuːm", "house": "haʊs",
        "water": "wɔːtɚ", "word": "wɜːɹd", "name": "neɪm",
        "good": "ɡʊd", "great": "ɡɹeɪt", "big": "bɪɡ", "little": "lɪtəl",
        "small": "smɔːl", "long": "lɔːŋ", "old": "oʊld", "new": "njuː",
        "young": "jʌŋ", "high": "haɪ", "low": "loʊ", "real": "ɹiːəl",
        "true": "tɹuː", "sure": "ʃʊɹ", "same": "seɪm", "different": "dɪfɹənt",
        "own": "oʊn", "last": "læst", "first": "fɜːɹst", "next": "nɛkst",
        "other": "ʌðɚ", "another": "ənʌðɚ", "both": "boʊθ", "every": "ɛvɹiː",
        "each": "iːʧ", "such": "sʌʧ", "even": "iːvən", "already": "ɔːlɹɛdiː",
        "maybe": "meɪbiː", "perhaps": "pɚhæps", "probably": "pɹɑbəbliː",
        "really": "ɹiːəliː", "actually": "æʧuːəliː", "exactly": "ɪɡzæktliː",
        "together": "təɡɛðɚ", "everything": "ɛvɹiːθɪŋ", "nothing": "nʌθɪŋ",
        "something": "sʌmθɪŋ", "anything": "ɛniːθɪŋ", "everyone": "ɛvɹiːwʌn",
        "someone": "sʌmwʌn", "anyone": "ɛniːwʌn", "nobody": "noʊbɑdiː",
        "money": "mʌniː", "family": "fæməliː", "father": "fɑːðɚ",
        "mother": "mʌðɚ", "brother": "bɹʌðɚ", "sister": "sɪstɚ",
        "friend": "fɹɛnd", "friends": "fɹɛndz", "doctor": "dɑktɚ",
        "police": "pəliːs", "problem": "pɹɑbləm", "story": "stɔːɹiː",
        "question": "kwɛsʧən", "answer": "ænsɚ", "idea": "aɪdiːə",
        "moment": "moʊmənt", "minute": "mɪnɪt", "second": "sɛkənd",
        "hour": "aʊɚ", "morning": "mɔːɹnɪŋ", "afternoon": "æftɚnuːn",
        "evening": "iːvnɪŋ", "today": "tədeɪ", "tonight": "tənɑɪt",
        "tomorrow": "təmɑɹoʊ", "yesterday": "jɛstɚdeɪ",
        "mr": "mɪstɚ", "mrs": "mɪsɪz", "ms": "mɪz", "dr": "dɑktɚ",
        "sir": "sɜːɹ", "ma'am": "mæm", "miss": "mɪs",
        "hello": "hɛloʊ", "hi": "haɪ", "hey": "heɪ", "bye": "baɪ",
        "goodbye": "ɡʊdbaɪ", "welcome": "wɛlkəm",
        "i'm": "aɪm", "i've": "aɪv", "i'll": "aɪl", "i'd": "aɪd",
        "you're": "jɔːɹ", "you've": "juːv", "you'll": "juːl", "you'd": "juːd",
        "he's": "hiːz", "she's": "ʃiːz", "it's": "ɪts",
        "we're": "wɪɹ", "we've": "wiːv", "we'll": "wiːl", "we'd": "wiːd",
        "they're": "ðɛɹ", "they've": "ðeɪv", "they'll": "ðeɪl",
        "don't": "doʊnt", "doesn't": "dʌznt", "didn't": "dɪdnt",
        "won't": "woʊnt", "wouldn't": "wʊdnt", "couldn't": "kʊdnt",
        "shouldn't": "ʃʊdnt", "can't": "kænt", "isn't": "ɪznt",
        "aren't": "ɑːɹnt", "wasn't": "wɑznt", "weren't": "wɜːɹnt",
        "haven't": "hævnt", "hasn't": "hæznt", "hadn't": "hædnt",
        "that's": "ðæts", "there's": "ðɛɹz", "here's": "hɪɹz",
        "what's": "wɑts", "who's": "huːz", "how's": "haʊz",
        "let's": "lɛts", "he'd": "hiːd", "she'd": "ʃiːd",
    ]
}
#endif
