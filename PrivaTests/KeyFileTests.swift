import XCTest
@testable import Priva

/// Key files: a 24-word key saved as a file that opens only with the Priva password, in Priva on the Apple Account
/// that bought it.
nonisolated final class KeyFileTests: XCTestCase {
    private let fast = 1 << 14
    private let account = "2000000123456789"

    func testOpensWithThePasswordOnTheSameAppleAccount() throws {
        let seed = Bytes.random(32)
        let file = try KeyFile.seal(seed, kind: .recovery, password: "correct horse battery", purchaseID: account, rounds: fast)
        XCTAssertEqual(try KeyFile.open(file, expecting: .recovery, password: "correct horse battery", purchaseID: account), seed)
        XCTAssertEqual(RecoveryPhrase.encode(try KeyFile.open(file, expecting: .recovery, password: "correct horse battery", purchaseID: account)),
                       RecoveryPhrase.encode(seed))
        XCTAssertEqual(try KeyFile.peek(file).kind, .recovery)
    }

    func testAWrongPasswordOrAnotherAppleAccountIsTheSameRefusal() throws {
        let file = try KeyFile.seal(Bytes.random(32), kind: .backup, password: "correct horse battery", purchaseID: account, rounds: fast)
        XCTAssertThrowsError(try KeyFile.open(file, expecting: .backup, password: "correct horse batterY", purchaseID: account)) {
            XCTAssertEqual($0 as? KeyFile.Failure, .wrongPasswordOrAccount)
        }
        XCTAssertThrowsError(try KeyFile.open(file, expecting: .backup, password: "correct horse battery", purchaseID: "2000000123456780")) {
            XCTAssertEqual($0 as? KeyFile.Failure, .wrongPasswordOrAccount, "someone else's copy of Priva can't open it, even with the password")
        }
    }

    /// Moving to a different Apple Account: the file still opens with the old account's purchase ID, saved in the
    /// vault (and its backups) or typed in from Settings, spaces and line breaks from copying included.
    func testAnotherAccountsPurchaseIDOpensItWhenGiven() throws {
        let seed = Bytes.random(32)
        let file = try KeyFile.seal(seed, kind: .recovery, password: "pw", purchaseID: account, rounds: fast)
        let thisAccount = "2000000999999999"
        XCTAssertThrowsError(try KeyFile.open(file, expecting: .recovery, password: "pw", purchaseIDs: [thisAccount]))
        XCTAssertEqual(try KeyFile.open(file, expecting: .recovery, password: "pw", purchaseIDs: [thisAccount, account]), seed)
        XCTAssertEqual(try KeyFile.open(file, expecting: .recovery, password: "pw", purchaseIDs: [" 2000000 1234\n56789 "]), seed)
        XCTAssertThrowsError(try KeyFile.open(file, expecting: .recovery, password: "pw", purchaseIDs: []), "no ID, no file")
        XCTAssertThrowsError(try KeyFile.open(file, expecting: .recovery, password: "wrong", purchaseIDs: [thisAccount, account]),
                             "the purchase ID never replaces the password")
    }

    func testTheRecoveryAndBackupKeysCantBeMixedUp() throws {
        let file = try KeyFile.seal(Bytes.random(32), kind: .backup, password: "pw", purchaseID: account, rounds: fast)
        XCTAssertThrowsError(try KeyFile.open(file, expecting: .recovery, password: "pw", purchaseID: account)) {
            XCTAssertEqual($0 as? KeyFile.Failure, .wrongKind(.backup))
        }
        // Relabeling the header doesn't help: the kind is bound into the key and the authenticated data.
        let original = try KeyFile.peek(file)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        enc.dateEncodingStrategy = .secondsSince1970
        let core = try enc.encode(KeyFile.Header(kind: .recovery, created: original.created, salt: original.salt, rounds: original.rounds))
        var relabeled = KeyFile.magic
        relabeled.appendBE(UInt32(core.count))
        relabeled.append(core)
        relabeled.append(file.suffix(76))
        XCTAssertEqual(try KeyFile.peek(relabeled).kind, .recovery)
        XCTAssertThrowsError(try KeyFile.open(relabeled, expecting: .recovery, password: "pw", purchaseID: account)) {
            XCTAssertEqual($0 as? KeyFile.Failure, .wrongPasswordOrAccount)
        }
    }

    func testEveryChangedByteIsRefused() throws {
        let seed = Bytes.random(32)
        let file = try KeyFile.seal(seed, kind: .recovery, password: "pw", purchaseID: account, rounds: fast)
        // Every byte of the box and a sample of the header (each header byte costs a scrypt run).
        let header = Array(stride(from: 0, to: file.count - 76, by: 9)), box = Array((file.count - 76)..<file.count)
        for i in header + box {
            var t = file
            t[i] ^= 0x01
            XCTAssertThrowsError(try KeyFile.open(t, expecting: .recovery, password: "pw", purchaseID: account), "byte \(i)")
        }
        XCTAssertThrowsError(try KeyFile.open(file.dropLast(), expecting: .recovery, password: "pw", purchaseID: account))
        XCTAssertThrowsError(try KeyFile.open(file + Data([0]), expecting: .recovery, password: "pw", purchaseID: account))
    }

    func testNothingReadableInTheFile() throws {
        let seed = Bytes.random(32)
        let a = try KeyFile.seal(seed, kind: .recovery, password: "pw", purchaseID: account, rounds: fast)
        let b = try KeyFile.seal(seed, kind: .recovery, password: "pw", purchaseID: account, rounds: fast)
        XCTAssertNotEqual(a, b, "fresh salt and nonce every time")
        for f in [a, b] {
            XCTAssertNil(f.range(of: seed))
            XCTAssertNil(f.range(of: Data(account.utf8)), "the Apple purchase ID isn't in the file")
            XCTAssertNil(f.range(of: Data(RecoveryPhrase.encode(seed)[0].utf8)))
        }
    }

    /// A crafted file can't make the app reserve gigabytes, and junk is refused before any work.
    func testCraftedFilesAreRefusedCheaply() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let header = KeyFile.Header(kind: .recovery, created: .now, salt: Bytes.random(32), rounds: 1 << 30)
        let core = try enc.encode(header)
        var file = KeyFile.magic
        file.appendBE(UInt32(core.count))
        file.append(core)
        file.append(Bytes.random(76))
        let start = Date()
        XCTAssertThrowsError(try KeyFile.open(file, expecting: .recovery, password: "pw", purchaseID: account)) {
            XCTAssertEqual($0 as? KeyFile.Failure, .notAKeyFile)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        for junk in [Data(), Data("PRIVABK1".utf8) + Bytes.random(200), Bytes.random(KeyFile.maxSize + 1), KeyFile.magic + Data([0xFF, 0xFF, 0xFF, 0xFF])] {
            XCTAssertThrowsError(try KeyFile.peek(junk)) { XCTAssertEqual($0 as? KeyFile.Failure, .notAKeyFile) }
        }
    }

    /// The real setting (scrypt 2¹⁷, 128 MiB): what the user waits for, and what a guess costs an attacker.
    func testRealStretchCost() throws {
        let seed = Bytes.random(32)
        var start = Date()
        let file = try KeyFile.seal(seed, kind: .recovery, password: "pw", purchaseID: account)
        let sealTime = Date().timeIntervalSince(start)
        start = Date()
        XCTAssertEqual(try KeyFile.open(file, expecting: .recovery, password: "pw", purchaseID: account), seed)
        let openTime = Date().timeIntervalSince(start)
        print("KEYFILE seal \(Int(sealTime * 1000)) ms, open \(Int(openTime * 1000)) ms, \(file.count) bytes")
        XCTAssertLessThan(file.count, 512)
    }

    @MainActor func testTheDevelopmentPurchaseIDIsStable() async throws {
        let a = try await PurchaseService.purchaseID()
        let b = try await PurchaseService.purchaseID()
        XCTAssertEqual(a, b, "the same Apple Account always opens its own files")
    }
}
