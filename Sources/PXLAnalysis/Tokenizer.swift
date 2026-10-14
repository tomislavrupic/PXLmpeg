import Foundation

/// Original Swift implementation of the CLIP byte-level BPE representation.
/// Vocabulary and merge data are host-supplied model assets, never bundled in the core.
public struct CLIPTokenizer: Sendable {
  private struct Pair: Hashable, Sendable {
    let a: String
    let b: String
  }
  private let vocabulary: [String: Int32]
  private let ranks: [Pair: Int]
  private let bytes: [String]
  public init(directory: URL) throws {
    let vocab = try boundedData(
      at: directory.appendingPathComponent("clip-vocab.json"), maximum: 4 * 1024 * 1024)
    let merges = try boundedData(
      at: directory.appendingPathComponent("clip-merges.txt"), maximum: 4 * 1024 * 1024)
    guard vocab.count <= 4 * 1024 * 1024, merges.count <= 4 * 1024 * 1024,
      let text = String(data: merges, encoding: .utf8)
    else { throw analysisError("Invalid tokenizer assets") }
    try self.init(vocabulary: JSONDecoder().decode([String: Int32].self, from: vocab), merges: text)
  }
  init(vocabulary: [String: Int32], merges: String) throws {
    guard vocabulary.count <= 50_000, vocabulary["<|startoftext|>"] == 49406,
      vocabulary["<|endoftext|>"] == 49407,
      vocabulary.values.allSatisfy({ (0...49407).contains($0) }),
      Set(vocabulary.values).count == vocabulary.count
    else { throw analysisError("Invalid CLIP vocabulary") }
    self.vocabulary = vocabulary
    var ranks: [Pair: Int] = [:]
    let lines = merges.split(separator: "\n", omittingEmptySubsequences: true)
    guard lines.count <= 300_000, lines.first?.hasPrefix("#version:") == true else {
      throw analysisError("Too many BPE merges")
    }
    for line in lines.dropFirst().prefix(48_894) {
      let fields = line.split(separator: " ")
      guard fields.count == 2 else { throw analysisError("Invalid BPE merge") }
      let pair = Pair(a: String(fields[0]), b: String(fields[1]))
      guard ranks[pair] == nil else { throw analysisError("Repeated BPE merge") }
      ranks[pair] = ranks.count
    }
    self.ranks = ranks
    let visible = Array(33...126) + Array(161...172) + Array(174...255)
    var table = Array(repeating: "", count: 256)
    for byte in visible { table[byte] = String(UnicodeScalar(byte)!) }
    var extra = 256
    for byte in 0..<256 where table[byte].isEmpty {
      table[byte] = String(UnicodeScalar(extra)!)
      extra += 1
    }
    self.bytes = table
  }

  public func encode(_ text: String) throws -> [Int32] {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 8192
    else {
      throw analysisError("Query must contain 1...8192 UTF-8 bytes")
    }
    let clean = text.lowercased()
    let regex = try NSRegularExpression(
      pattern:
        #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#
    )
    let ns = clean as NSString
    var result: [Int32] = [49406]
    for match in regex.matches(in: clean, range: NSRange(location: 0, length: ns.length)) {
      let part = ns.substring(with: match.range)
      guard part != "<|startoftext|>", part != "<|endoftext|>" else {
        throw analysisError("Reserved token in query")
      }
      var word = part.utf8.map { bytes[Int($0)] }
      if word.isEmpty { continue }
      word[word.count - 1] += "</w>"
      while word.count > 1 {
        var best: (Pair, Int)?
        for i in 0..<(word.count - 1) {
          let pair = Pair(a: word[i], b: word[i + 1])
          if let rank = ranks[pair], rank < (best?.1 ?? Int.max) { best = (pair, rank) }
        }
        guard let pair = best?.0 else { break }
        var merged: [String] = []
        var i = 0
        while i < word.count {
          if i + 1 < word.count, word[i] == pair.a, word[i + 1] == pair.b {
            merged.append(word[i] + word[i + 1])
            i += 2
          } else {
            merged.append(word[i])
            i += 1
          }
        }
        word = merged
      }
      for unit in word {
        guard let token = vocabulary[unit] else {
          throw analysisError("Tokenizer cannot encode query unit")
        }
        result.append(token)
        guard result.count <= 76 else { throw analysisError("Query exceeds 75 content tokens") }
      }
    }
    result.append(49407)
    return result + Array(repeating: 0, count: 77 - result.count)
  }
}
