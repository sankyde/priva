import CryptoKit
import Foundation
import StoreKit

/// Turns "this Apple Account bought Priva" into ONE anonymous registration token, then forgets
/// the purchase entirely. After `obtainToken()` returns, nothing on this device or on the server
/// connects the purchase to the username that the token will later register.
nonisolated enum PurchaseService {
    enum Failure: Error, Equatable { case notPurchased, network, limitReached, verification }

    private static let tokenAccount = "purchase.token"

    enum Proof { case appStore(jws: String), development(nonce: Data) }

    static func proof() async throws -> Proof {
        #if DEBUG
        // Simulator / Xcode builds have no App Store receipt. The server only accepts this path while
        // `allow_dev_purchases` is true, which must be switched off before release. The simulated
        // purchase ID persists across reinstalls, exactly like a real appTransactionID.
        if let n = developmentNonce { return .development(nonce: n) }
        let n = Bytes.random(32)
        developmentNonce = n
        return .development(nonce: n)
        #else
        do {
            let result = try await AppTransaction.shared
            return .appStore(jws: result.jwsRepresentation)
        } catch {
            throw Failure.notPurchased
        }
        #endif
    }

    /// Which Apple Account bought Priva: the App Store's appTransactionID, one per Apple Account and the same on every
    /// iPhone and after reinstalling. Key files are bound to it (KeyFile); it is never sent anywhere for that.
    static func purchaseID() async throws -> String {
        #if DEBUG
        if let n = developmentNonce { return "dev:" + n.hex }
        let n = Bytes.random(32)
        developmentNonce = n
        return "dev:" + n.hex
        #else
        do {
            // payloadValue throws unless StoreKit verified Apple's signature.
            return try await AppTransaction.shared.payloadValue.appTransactionID
        } catch {
            throw Failure.notPurchased
        }
        #endif
    }

    /// Previously obtained (crash-safe) token, if registration has not completed yet.
    static var storedToken: BlindToken.Redeemable? { Keychain.getCodable(BlindToken.Redeemable.self, account: tokenAccount) }

    static func obtainToken() async throws -> BlindToken.Redeemable {
        if let t = storedToken { return t }
        let spki: Data
        do { spki = try await PrivaAPI.shared.issuerPublicKey() } catch { throw Failure.network }
        let pending = try BlindToken.begin(spki: spki)
        var proof: Proof? = try await self.proof()
        defer { proof = nil }
        let blindSig: Data
        do {
            switch proof! {
            case .appStore(let jws): blindSig = try await PrivaAPI.shared.issueToken(jws: jws, devNonce: nil, blinded: pending.blinded)
            case .development(let n): blindSig = try await PrivaAPI.shared.issueToken(jws: nil, devNonce: n, blinded: pending.blinded)
            }
        } catch APIError.http(409, _) {
            throw Failure.limitReached
        } catch APIError.http(429, _) {
            throw Failure.limitReached
        } catch APIError.http(403, _) {
            throw Failure.notPurchased
        } catch {
            throw Failure.network
        }
        let token: BlindToken.Redeemable
        do { token = try BlindToken.finish(pending, blindSignature: blindSig) } catch { throw Failure.verification }
        try Keychain.setCodable(token, account: tokenAccount)
        return token
    }

    /// Called once the username is registered: erases the last trace of the purchase flow.
    static func purge() { Keychain.delete(tokenAccount) }

    /// A development purchase signed with the operator's key (PRIVA_DEV_PURCHASE_KEY in .env, Debug builds only):
    /// the server takes development purchases only with it, so the published source alone can't mint them.
    static func developmentProof(_ nonce: Data) -> String? {
        #if DEBUG
        guard let key = Bundle.main.object(forInfoDictionaryKey: "PrivaDevPurchaseKey") as? String, key.count == 64 else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data("priva-dev-purchase-v1|".utf8) + nonce, using: SymmetricKey(data: Data(key.utf8)))
        return Data(mac).base64EncodedString()
        #else
        return nil
        #endif
    }

    /// Development-only stand-in for Apple's appTransactionID.
    static var developmentNonce: Data? {
        get {
            #if DEBUG
            return try? Keychain.get("purchase.devnonce")
            #else
            return nil
            #endif
        }
        set {
            #if DEBUG
            if let newValue { try? Keychain.set(newValue, account: "purchase.devnonce") } else { Keychain.delete("purchase.devnonce") }
            #endif
        }
    }
}
