#if DEBUG
import Foundation

/// Development-only launch switches used by the two-simulator test runs (compiled out of Release).
///   -PrivaReset YES      wipe vault + data at launch (fresh onboarding)
///   -PrivaAutofill YES   the app fills its own password fields with a random test password it generates
///                        and keeps in DEBUG-only defaults, so UI runs never need a password typed in.
///   -PrivaExportKeychainFactor YES / -PrivaImportKeychainFactor <hex>
///                        simulators have no iCloud Keychain to sync the backup's third factor to "another
///                        iPhone"; these stand in for that sync in the multi-simulator restore journey.
///   -PrivaForgetTour YES treat this install as a first download again (welcome tour journeys).
///   -PrivaIgnoreCapture YES  don't cover the screen while it's mirrored/recorded (journeys watched from a Mac).
///   -PrivaKeepPurchase YES  with -PrivaReset: keep the simulated purchase (an erased iPhone on the same Apple
///                        Account), so key files saved before the reset still open.
enum DebugAutomation {
    static func apply(to model: AppModel) {
        if UserDefaults.standard.bool(forKey: "PrivaExportKeychainFactor"), let f = BackupKeychainFactor.read() {
            print("PRIVA-F3 \(f.hex)")
        }
        if let hex = UserDefaults.standard.string(forKey: "PrivaImportKeychainFactor"), let f = Data(hex: hex), f.count == 32 {
            BackupKeychainFactor.debugInstall(f)
        }
        if UserDefaults.standard.bool(forKey: "PrivaForgetTour") { WelcomeTour.debugForget() }
        if UserDefaults.standard.bool(forKey: "PrivaReset") {
            // -PrivaKeepSecrets YES: simulate "erased phone, backups still here", keep the generated test
            // password and Backup Key so the restore journey can run without anyone typing secrets.
            let keep = UserDefaults.standard.bool(forKey: "PrivaKeepSecrets")
            let pw = UserDefaults.standard.string(forKey: "priva.debug.pw"), bk = backupKey
            let purchase = PurchaseService.developmentNonce
            model.wipe()
            if UserDefaults.standard.bool(forKey: "PrivaKeepPurchase") { PurchaseService.developmentNonce = purchase }
            UserDefaults.standard.removeObject(forKey: "priva.debug.pw")
            if keep {
                UserDefaults.standard.set(pw, forKey: "priva.debug.pw")
                backupKey = bk
            }
        }
    }

    /// The last Backup Key shown during an autofill run (DEBUG only; release builds never keep it).
    static var backupKey: String? {
        get { UserDefaults.standard.bool(forKey: "PrivaAutofill") ? UserDefaults.standard.string(forKey: "priva.debug.backupkey") : nil }
        set { UserDefaults.standard.set(newValue, forKey: "priva.debug.backupkey") }
    }

    static var testPassword: String? {
        guard UserDefaults.standard.bool(forKey: "PrivaAutofill") else { return nil }
        if let pw = UserDefaults.standard.string(forKey: "priva.debug.pw") { return pw }
        let words = (0..<5).map { _ in RecoveryPhrase.words.randomElement() ?? "priva" }
        let pw = words.joined(separator: "-") + "-\(Int.random(in: 10...99))"
        UserDefaults.standard.set(pw, forKey: "priva.debug.pw")
        return pw
    }
}
#endif
