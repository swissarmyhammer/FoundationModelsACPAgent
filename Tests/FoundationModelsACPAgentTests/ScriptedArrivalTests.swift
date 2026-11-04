import Testing

@testable import acp_agent

/// The scripted arrival that the signal watches of the unit tests use.
@Suite struct ScriptedArrivalTests {
  /// The error that the failing gate throws.
  private struct GateFailure: Error {}

  /// A gate that throws finishes the stream with no element, so a consumer
  /// that iterates the stream does not wait for ever.
  @Test func aGateThatThrowsFinishesTheStreamWithNoElement() async {
    let arrival = ScriptedArrival.after({ throw GateFailure() }, giving: 1)

    var elements: [Int] = []
    for await element in arrival.arrivals {
      elements.append(element)
    }

    #expect(elements.isEmpty)
  }

  /// A gate that returns gives the element, and then the stream finishes.
  @Test func aGateThatReturnsGivesTheElementAndFinishesTheStream() async {
    let arrival = ScriptedArrival.after({}, giving: 1)

    var elements: [Int] = []
    for await element in arrival.arrivals {
      elements.append(element)
    }

    #expect(elements == [1])
  }
}
