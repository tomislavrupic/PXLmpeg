import Foundation
import PXLMedia
import XCTest

@testable import PXLAnalysis

final class AnalysisTests: XCTestCase {
  func testVectorValidationAndCosineRanking() throws {
    let a = try Embedding.normalized([3, 4])
    XCTAssertEqual(a[0], 0.6, accuracy: 0.00001)
    XCTAssertEqual(a[1], 0.8, accuracy: 0.00001)
    for bad: [Float] in [[], [0, 0], [.nan, 1], [.infinity, 0]] {
      XCTAssertThrowsError(try Embedding.normalized(bad))
    }
    XCTAssertEqual(try Embedding.cosine([1, 0], [1, 0]), 1, accuracy: 0.00001)
    XCTAssertThrowsError(try Embedding.cosine([1, 0], [1]))
  }

  func testSamplingAndResourceLimitsRejectNonfiniteOrExcessiveRequests() throws {
    for interval in [0, -1, Double.nan, .infinity, 0.001] {
      XCTAssertThrowsError(try SamplingOptions(intervalSeconds: interval))
    }
    XCTAssertThrowsError(try SamplingOptions(maximumSamplesPerSource: 0))
    XCTAssertThrowsError(try SamplingOptions(maximumSamplesPerSource: 4097))
    XCTAssertNoThrow(try SamplingOptions(intervalSeconds: 0.25, maximumSamplesPerSource: 16))
  }

  func testTokenizerRejectsInvalidVocabularyAndUnknownUnits() throws {
    XCTAssertThrowsError(try CLIPTokenizer(vocabulary: [:], merges: "#version: 0.2\n"))
    let t = try CLIPTokenizer(
      vocabulary: ["<|startoftext|>": 49406, "<|endoftext|>": 49407, "a</w>": 320],
      merges: "#version: 0.2\n")
    XCTAssertEqual(try t.encode("A").prefix(3), [49406, 320, 49407])
    XCTAssertThrowsError(try t.encode("bad"))
    XCTAssertThrowsError(try t.encode(""))
    XCTAssertThrowsError(try t.encode(String(repeating: "a", count: 8193)))
    XCTAssertThrowsError(try t.encode(Array(repeating: "a", count: 76).joined(separator: " ")))
  }

  func testOfficialNativeTokenizerConformanceWhenAssetsPresent() throws {
    guard let root = ProcessInfo.processInfo.environment["PXL_SEMANTIC_MODELS"] else {
      throw XCTSkip("Set PXL_SEMANTIC_MODELS for optional real tokenizer/model validation")
    }
    let t = try CLIPTokenizer(directory: URL(fileURLWithPath: root))
    let examples: [(String, [Int32])] = [
      ("a photo of a cat", [49406, 320, 1125, 539, 320, 2368, 49407]),
      ("A red car!", [49406, 320, 736, 1615, 256, 49407]),
      ("a person walking through a door", [49406, 320, 2533, 3941, 1417, 320, 2489, 49407]),
      ("A café in Zagreb", [49406, 320, 15304, 530, 35355, 49407]),
      ("guitar, plant & chair", [49406, 5084, 267, 3912, 261, 4269, 49407]),
      ("don’t stop", [49406, 847, 728, 503, 339, 1691, 49407]),
      ("123", [49406, 272, 273, 274, 49407]),
    ]
    for (text, expected) in examples {
      let tokens = try t.encode(text)
      XCTAssertEqual(tokens.count, 77)
      XCTAssertEqual(Array(tokens.prefix(expected.count)), expected)
      XCTAssertTrue(tokens.dropFirst(expected.count).allSatisfy { $0 == 0 })
    }
  }
}
