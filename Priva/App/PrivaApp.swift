import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Every peer-to-peer connection holds a few UDP sockets; iOS's default open-file limit would run out with
    /// many simultaneous chats or a big group. Raise it within what the system allows.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        var rl = rlimit()
        if getrlimit(RLIMIT_NOFILE, &rl) == 0 {
            let want = min(rlim_t(4096), rl.rlim_max)
            if rl.rlim_cur < want { rl.rlim_cur = want; _ = setrlimit(RLIMIT_NOFILE, &rl) }
        }
        return true
    }

    /// Third-party keyboards can log keystrokes; Priva only allows Apple's system keyboard.
    func application(_ application: UIApplication, shouldAllowExtensionPointIdentifier id: UIApplication.ExtensionPointIdentifier) -> Bool {
        id != .keyboard
    }
}

@main
struct PrivaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.tint)
                .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
                .onChange(of: scenePhase) { _, p in model.scenePhaseChanged(p) }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch model.phase {
            case .onboarding:
                OnboardingFlow().transition(.opacity)
            case .welcomeBack:
                WelcomeBackView().transition(.opacity)
            case .locked:
                LockView().transition(.opacity.combined(with: .scale(scale: 1.02)))
            case .finishingSetup:
                NavigationStack { CreatingAccountView() }.transition(.opacity)
            case .restoring:
                VStack(spacing: 18) {
                    ProgressView().controlSize(.large)
                    Text("Restoring your account…").font(.headline).foregroundStyle(Theme.textSecondary)
                }
                .transition(.opacity)
            case .unlocked:
                if let engine = model.engine {
                    @Bindable var m = model
                    MainView().environment(engine).transition(.opacity.combined(with: .scale(scale: 0.98)))
                        // Only while unlocked: locking closes it (unfinished, so it comes back next time).
                        .fullScreenCover(isPresented: $m.showTour) { WelcomeTourView().environment(model).environment(engine) }
                }
            }
            if model.privacyCover { PrivacyCover().transition(.opacity).zIndex(10) }
        }
        .hiddenWhileCaptured()
        .alert("Restore didn't finish", isPresented: Binding(get: { model.restoreError != nil }, set: { if !$0 { model.restoreError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.restoreError ?? "") }
        .onOpenURL { model.received($0) }
        .animation(Theme.gentle, value: model.phase)
        .animation(.easeOut(duration: 0.15), value: model.privacyCover)
    }
}

/// Shown over the app whenever it is not active, so the app-switcher snapshot reveals nothing.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Theme.background.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 14) {
                PrivaMark().frame(width: 84, height: 84)
                Text("Priva").font(.brandTitle).foregroundStyle(Theme.textPrimary)
            }
        }
        .accessibilityHidden(true)
    }
}
