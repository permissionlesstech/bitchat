import Foundation
import Testing
@testable import bitchat

@Suite(.serialized)
struct BitchatHarnessServiceTests {
    @Test func decodesServiceRequestArguments() throws {
        let line = #"{"arguments":{"channel":"mesh","text":"hello","to":"alice"},"command":"send"}"#
        let request = try HarnessServiceRequest.decode(line)

        #expect(request.command == "send")
        #expect(request.string("text") == "hello")
        #expect(request.string("to") == "alice")
        #expect(request.string("channel") == "mesh")
    }

    @Test func encodesServiceResponseAsJSONLines() throws {
        let line = try HarnessServiceResponse.encodeLines([
            ["type": "service", "status": "running"],
            ["type": "status", "backend_mode": "live"]
        ])

        let rows = line.split(separator: "\n").map(String.init)
        #expect(rows.count == 2)
        #expect(rows[0].contains(#""service""#))
        #expect(rows[1].contains(#""live""#))
    }
}
