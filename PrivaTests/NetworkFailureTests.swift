import XCTest
@testable import Priva

/// How the app takes server failures (audit TST-01): every answer here comes from a URLProtocol stub, so nothing
/// touches the network and each failure is exact. Runs offline.
nonisolated final class NetworkFailureTests: XCTestCase {
    /// path suffix → what the "server" does.
    enum Answer { case status(Int, Data, [String: String]), fail(URLError.Code) }
    nonisolated(unsafe) static var answers: [String: Answer] = [:]

    final class Stub: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url?.path ?? ""
            guard let answer = NetworkFailureTests.answers.first(where: { path.hasSuffix($0.key) })?.value else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            switch answer {
            case .fail(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            case .status(let code, let body, let headers):
                let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() {}
    }

    override func setUp() {
        super.setUp()
        Self.answers = [:]
        PrivaAPI.debugProtocolClasses = [Stub.self]
    }

    override func tearDown() {
        PrivaAPI.debugProtocolClasses = nil
        Self.answers = [:]
        ServerClock.debugSet(0)
        super.tearDown()
    }

    private let lookup = "rpc/lookup_directory"
    private let commit = Bytes.random(32)

    func testAServerErrorIsReportedNotTakenAsAnAnswer() async {
        Self.answers[lookup] = .status(503, Data("upstream".utf8), [:])
        do {
            _ = try await PrivaAPI.shared.lookup(commit: commit)
            XCTFail("a 503 isn't a directory answer")
        } catch APIError.http(let code, _) {
            XCTAssertEqual(code, 503)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testATimeoutIsANetworkError() async {
        Self.answers[lookup] = .fail(.timedOut)
        do {
            _ = try await PrivaAPI.shared.lookup(commit: commit)
            XCTFail("a timeout isn't an answer")
        } catch APIError.network {
        } catch { XCTFail("unexpected \(error)") }
    }

    func testAMalformedDirectoryAnswerIsRefused() async {
        Self.answers[lookup] = .status(200, Data("<html>not json</html>".utf8), [:])
        do {
            _ = try await PrivaAPI.shared.lookup(commit: commit)
            XCTFail("garbage isn't a directory entry")
        } catch {}
        Self.answers[lookup] = .status(200, Data(#"[{"lease_week":"2026-W40","bundle":"AAAA"}]"#.utf8), [:])
        do {
            _ = try await PrivaAPI.shared.lookup(commit: commit)
            XCTFail("a bundle that doesn't parse is refused")
        } catch {}
    }

    func testAnEmptyAnswerMeansTheNameIsGone() async throws {
        Self.answers[lookup] = .status(200, Data("[]".utf8), [:])
        let entry = try await PrivaAPI.shared.lookup(commit: commit)
        XCTAssertEqual(entry.status, .removed)
        XCTAssertNil(entry.bundle)
    }

    /// A server clock far off moves the protocol clock by at most an hour, but the pass day follows the server
    /// (audit TST-03, SEC-25).
    func testAServerClockFarOffIsClampedButSetsThePassDay() async throws {
        let ahead = Date().addingTimeInterval(2 * 86_400)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        Self.answers[lookup] = .status(200, Data("[]".utf8), ["Date": f.string(from: ahead)])
        _ = try await PrivaAPI.shared.lookup(commit: commit)
        XCTAssertEqual(ServerClock.offset, ServerClock.maxOffset, "the signal clock moves an hour at most")
        let server = try XCTUnwrap(ServerClock.serverNow)
        XCTAssertEqual(server.timeIntervalSince(ahead), 0, accuracy: 5)
        XCTAssertEqual(RelayPass.today, Int(floor(ahead.timeIntervalSince1970 / 86_400)), "the pass day is the server's")
    }
}
