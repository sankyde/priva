#if DEBUG
import Foundation

/// Tests only (compiled out of Release): every byte Priva hands to a network API, exactly as it leaves or
/// enters the app. Lets the security tests prove that nothing readable is ever sent, stored or relayed.
///   "https"  request line + body of every HTTPS call        "ws-out" / "ws-in"  rendezvous WebSocket frames
///   "dc"     sealed data-channel frames (control + bulk)
nonisolated enum WireTap {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: (@Sendable (String, Data) -> Void)?

    static func install(_ s: (@Sendable (String, Data) -> Void)?) {
        lock.lock(); sink = s; lock.unlock()
    }

    static func record(_ channel: String, _ bytes: Data?) {
        guard let bytes else { return }
        lock.lock(); let s = sink; lock.unlock()
        s?(channel, bytes)
    }
}
#endif
