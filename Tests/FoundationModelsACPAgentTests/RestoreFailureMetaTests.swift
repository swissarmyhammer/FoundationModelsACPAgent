import FoundationModelsACP
import Testing

@testable import FoundationModelsACPAgent

/// The `_meta` of a child that did not restore. The write cannot fail, so the announcement of
/// the failure always carries its reason. It must equal what the typed payload writes.
@Suite struct RestoreFailureMetaTests {
  /// The reason in the tests.
  private static let reason = "the session file is missing"

  /// The `_meta` values that a child announcement can hold before the failure is written.
  private static let metas: [FoundationModelsACP.JSONValue?] = [
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
    .object(["sah": .string("not an object")]),
    .string("not an object"),
  ]

  /// The written `_meta` equals the `_meta` that the typed payload writes, for each shape.
  @Test(arguments: metas)
  func theWriteEqualsTheTypedPayload(meta: FoundationModelsACP.JSONValue?) throws {
    let failure = SAH.RestoreFailure(reason: Self.reason)

    #expect(failure.written(into: meta) == (try failure.inject(into: meta)))
  }

  /// The reason reads back from the written `_meta`.
  @Test func theReasonReadsBack() {
    let failure = SAH.RestoreFailure(reason: Self.reason)

    #expect(SAH.RestoreFailure.extract(from: failure.written(into: nil)) == failure)
  }
}
