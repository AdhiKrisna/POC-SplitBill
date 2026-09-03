import Foundation

struct OCRWord: Sendable {
    let text: String
    /// Normalized top-left coordinate space in the range 0...1.
    let boundingBox: CGRect
    let confidence: Float
}

struct LayoutToken: Sendable, Hashable {
    let token: String
    let tokenId: Int
    let wordIndex: Int?
    let bbox: [Int]
}

struct TokenPrediction: Sendable, Hashable {
    let tokenIndex: Int
    let token: String
    let wordIndex: Int?
    let labelID: Int
    let label: String
    let confidence: Float
}

enum LayoutLMv3TokenizerError: LocalizedError {
    case missingTokenizer
    case invalidTokenizer(String)
    case unknownToken(String)

    var errorDescription: String? {
        switch self {
        case .missingTokenizer:
            return "tokenizer.json is missing from the app target."
        case .invalidTokenizer(let reason):
            return "tokenizer.json is invalid: \(reason)"
        case .unknownToken(let token):
            return "Tokenizer produced an unknown token: \(token)"
        }
    }
}

/// Minimal RoBERTa-compatible byte-level BPE reader for the exported
/// LayoutLMv3 tokenizer.json. Keep parity tests against Hugging Face before
/// treating this prototype as production tokenization.
final class LayoutLMv3Tokenizer {
    let clsTokenID: Int
    let padTokenID: Int
    let sepTokenID: Int
    let unknownTokenID: Int
    let clsTokenBox: [Int]
    let sepTokenBox: [Int]
    let padTokenBox: [Int]

    private let vocabulary: [String: Int]
    private let mergeRanks: [String: Int]
    private let byteEncoder: [UInt8: Character]
    private var cache: [String: [String]] = [:]

    init(url: URL, configURL: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LayoutLMv3TokenizerError.missingTokenizer
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              model["type"] as? String == "BPE",
              let rawVocabulary = model["vocab"] as? [String: Any],
              let merges = model["merges"] as? [Any] else {
            throw LayoutLMv3TokenizerError.invalidTokenizer("expected a BPE model with vocab and merges")
        }

        var vocabulary: [String: Int] = [:]
        for (token, rawID) in rawVocabulary {
            guard let id = rawID as? Int else {
                throw LayoutLMv3TokenizerError.invalidTokenizer("non-integer vocabulary ID")
            }
            vocabulary[token] = id
        }
        self.vocabulary = vocabulary
        clsTokenID = vocabulary["<s>"] ?? 0
        padTokenID = vocabulary["<pad>"] ?? 1
        sepTokenID = vocabulary["</s>"] ?? 2
        unknownTokenID = vocabulary["<unk>"] ?? 3

        let configData: Data
        do {
            configData = try Data(contentsOf: configURL)
        } catch {
            throw LayoutLMv3TokenizerError.invalidTokenizer("tokenizer_config.json is missing")
        }
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw LayoutLMv3TokenizerError.invalidTokenizer("tokenizer_config.json is invalid")
        }
        clsTokenBox = try Self.specialBox(named: "cls_token_box", in: config)
        sepTokenBox = try Self.specialBox(named: "sep_token_box", in: config)
        padTokenBox = try Self.specialBox(named: "pad_token_box", in: config)

        var mergeRanks: [String: Int] = [:]
        for (rank, rawMerge) in merges.enumerated() {
            let pair: [String]
            if let values = rawMerge as? [String], values.count == 2 {
                pair = values
            } else if let value = rawMerge as? String {
                pair = value.split(separator: " ", maxSplits: 1).map(String.init)
            } else {
                throw LayoutLMv3TokenizerError.invalidTokenizer("unsupported merge entry at index \(rank)")
            }
            guard pair.count == 2 else {
                throw LayoutLMv3TokenizerError.invalidTokenizer("invalid merge entry at index \(rank)")
            }
            mergeRanks[Self.pairKey(pair[0], pair[1])] = rank
        }
        self.mergeRanks = mergeRanks
        byteEncoder = Self.makeByteEncoder()
    }

    func tokenize(word: String) throws -> [(token: String, id: Int)] {
        // LayoutLMv3 uses add_prefix_space=true when tokenizing pre-split words.
        let pieces = try pretokenize(" " + word)
        return pieces.flatMap { piece in
            let encoded = piece.utf8.map { byteEncoder[$0]! }
            let byteLevel = String(encoded)
            return bpe(byteLevel).map { token in
                guard let id = vocabulary[token] else {
                    return (token: token, id: unknownTokenID)
                }
                return (token: token, id: id)
            }
        }
    }

    private func pretokenize(_ text: String) throws -> [String] {
        let pattern = #"'(?:s|t|re|ve|m|ll|d)| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            throw LayoutLMv3TokenizerError.invalidTokenizer("byte-level pre-tokenizer regex failed")
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func bpe(_ token: String) -> [String] {
        if let cached = cache[token] { return cached }
        var symbols = token.map(String.init)
        guard symbols.count > 1 else {
            cache[token] = symbols
            return symbols
        }

        while true {
            var bestIndex: Int?
            var bestRank = Int.max
            for index in 0..<(symbols.count - 1) {
                let rank = mergeRanks[Self.pairKey(symbols[index], symbols[index + 1])] ?? Int.max
                if rank < bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }
            guard let index = bestIndex, bestRank < Int.max else { break }
            let first = symbols[index]
            let second = symbols[index + 1]
            var merged: [String] = []
            var cursor = 0
            while cursor < symbols.count {
                if cursor + 1 < symbols.count,
                   symbols[cursor] == first,
                   symbols[cursor + 1] == second {
                    merged.append(first + second)
                    cursor += 2
                } else {
                    merged.append(symbols[cursor])
                    cursor += 1
                }
            }
            symbols = merged
        }
        cache[token] = symbols
        return symbols
    }

    private static func pairKey(_ first: String, _ second: String) -> String {
        first + "\u{0001}" + second
    }

    private static func specialBox(named name: String, in config: [String: Any]) throws -> [Int] {
        guard let rawBox = config[name] as? [Any], rawBox.count == 4 else {
            throw LayoutLMv3TokenizerError.invalidTokenizer("missing \(name)")
        }
        let box = try rawBox.map { value -> Int in
            guard let number = value as? NSNumber else {
                throw LayoutLMv3TokenizerError.invalidTokenizer("invalid \(name)")
            }
            return number.intValue
        }
        guard box.allSatisfy({ 0...1000 ~= $0 }) else {
            throw LayoutLMv3TokenizerError.invalidTokenizer("out-of-range \(name)")
        }
        return box
    }

    private static func makeByteEncoder() -> [UInt8: Character] {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var codePoints = bytes
        var extra = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte)
            codePoints.append(256 + extra)
            extra += 1
        }
        var result: [UInt8: Character] = [:]
        for (byte, codePoint) in zip(bytes, codePoints) {
            if let scalar = UnicodeScalar(codePoint) {
                result[UInt8(byte)] = Character(String(scalar))
            }
        }
        return result
    }
}
