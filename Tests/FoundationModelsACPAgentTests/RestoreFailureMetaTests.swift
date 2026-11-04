import FoundationModelsACP
import Testing

@testable import FoundationModelsACPAgent

/// The `_meta` of a child that did not restore. The write cannot fail, so the announcement of
/// the failure always carries its reason.
///
/// Contract: for a `_meta` or `_meta.sah` that is an object, `null` or absent, the write equals
/// what the typed payload writes (``SAH/RestoreFailure/inject(into:)``). For a `_meta` or
/// `_meta.sah` that is another value (string, number, bool, array) the library encoder returns
/// the value unchanged, which drops the reason. The write here replaces that value with a fresh
/// object that holds the reason, because the reason of a failed child must reach the client and
/// a non-object `_meta` carries nothing else that a client can read.
@Suite struct RestoreFailureMetaTests {
  /// The reason in the tests.
  private static let reason = "the session file is missing"

  /// The `_meta` values that the typed payload writes into.
  private static let objectMetas: [FoundationModelsACP.JSONValue?] = [
    nil,
    .null,
    .object([:]),
    .object(["other": .string("kept")]),
    .object(["sah": .object(["agentRun": .string("kept")])]),
    .object([
      "sah": .object([
        "restoreFailure": .object(["reason": .string("old")]), "agentRun": .string("kept"),
      ])
    ]),
    .object(["sah": .null, "other": .string("kept")]),
  ]

  /// The `_meta` values that are not objects, or hold a `sah` that is not an object, with the
  /// `_meta` that the write must give.
  private static let nonObjectMetas:
    [(meta: FoundationModelsACP.JSONValue, written: FoundationModelsACP.JSONValue)] = {
      let fresh = FoundationModelsACP.JSONValue.object([
        "sah": .object(["restoreFailure": .object(["reason": .string(reason)])])
      ])
      return [
        (.string("not an object"), fresh),
        (.number(1), fresh),
        (.bool(true), fresh),
        (.array([.string("a")]), fresh),
        (
          .object(["sah": .string("not an object")]),
          fresh
        ),
        (
          .object(["sah": .array([]), "other": .string("kept")]),
          .object([
            "other": .string("kept"),
            "sah": .object(["restoreFailure": .object(["reason": .string(reason)])]),
          ])
        ),
      ]
    }()

  /// The written `_meta` equals the `_meta` that the typed payload writes, for each object shape.
  @Test(arguments: objectMetas)
  func theWriteEqualsTheTypedPayload(meta: FoundationModelsACP.JSONValue?) throws {
    let failure = SAH.RestoreFailure(reason: Self.reason)

    #expect(failure.written(into: meta) == (try failure.inject(into: meta)))
  }

  /// The reason reads back from the written `_meta`, for each object shape.
  @Test(arguments: objectMetas)
  func theReasonReadsBackFromAnObjectMeta(meta: FoundationModelsACP.JSONValue?) {
    let failure = SAH.RestoreFailure(reason: Self.reason)

    #expect(SAH.RestoreFailure.extract(from: failure.written(into: meta)) == failure)
  }

  /// The reason reads back from the written `_meta`.
  @Test func theReasonReadsBack() {
    let failure = SAH.RestoreFailure(reason: Self.reason)

    #expect(SAH.RestoreFailure.extract(from: failure.written(into: nil)) == failure)
  }

  /// A `_meta` or `_meta.sah` that is not an object gets a fresh object with the reason, and
  /// keeps the other members of `_meta`.
  @Test(arguments: nonObjectMetas.indices)
  func aNonObjectMetaIsReplacedByAnObjectWithTheReason(index: Int) {
    let shape = Self.nonObjectMetas[index]

    #expect(SAH.RestoreFailure(reason: Self.reason).written(into: shape.meta) == shape.written)
  }

  /// The reason reads back for each shape that is not an object.
  @Test(arguments: nonObjectMetas.indices)
  func theReasonReadsBackFromANonObjectMeta(index: Int) {
    let failure = SAH.RestoreFailure(reason: Self.reason)
    let shape = Self.nonObjectMetas[index]

    #expect(SAH.RestoreFailure.extract(from: failure.written(into: shape.meta)) == failure)
  }
}
