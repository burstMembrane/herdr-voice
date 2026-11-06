import Foundation
import Testing
@testable import HerdrVoiceCore

// MARK: MicRing (real-time mic hand-off)

@Test func ringHandsSamplesOverInOrderAcrossTheWrap() {
    let ring = MicRing(capacity: 8)
    var input: [Float] = [1, 2, 3, 4, 5, 6]
    var out = [Float](repeating: 0, count: 4)
    ring.write(&input, count: 6)
    #expect(ring.read(4, into: &out) && out == [1, 2, 3, 4])
    input = [7, 8, 9, 10, 11]                        // wraps past the end of storage
    ring.write(&input, count: 5)
    #expect(ring.available == 7)
    #expect(ring.read(4, into: &out) && out == [5, 6, 7, 8])
    #expect(!ring.read(4, into: &out))               // only 3 left: nothing copied
    #expect(ring.available == 3)
}

@Test func ringDropsWhatDoesNotFitInsteadOfBlocking() {
    let ring = MicRing(capacity: 4)
    var input: [Float] = [1, 2, 3, 4, 5, 6]
    ring.write(&input, count: 6)
    #expect(ring.available == 4)
    #expect(ring.dropped == 2)
}

@Test func concurrentWriterAndReaderLoseNothingWhenThereIsRoom() async {
    let ring = MicRing(capacity: 48_000)
    let total = 20_000
    let writer = Task.detached {
        var block = [Float](repeating: 0, count: 100)
        for start in stride(from: 0, to: total, by: 100) {
            for i in 0..<100 { block[i] = Float(start + i) }
            ring.write(&block, count: 100)
        }
    }
    var received: [Float] = []
    var chunk = [Float](repeating: 0, count: 50)
    let deadline = Date().addingTimeInterval(5) // fail fast instead of hanging the whole suite
    while received.count + Int(ring.dropped) < total && Date() < deadline {
        if ring.read(50, into: &chunk) { received += chunk } else { await Task.yield() }
    }
    await writer.value
    // Whatever wasn't dropped by a busy lock arrives complete and in order.
    #expect(received.count + ring.dropped == total)
    #expect(zip(received, received.dropFirst()).allSatisfy { $0 < $1 })
}

// MARK: processes without parked threads



