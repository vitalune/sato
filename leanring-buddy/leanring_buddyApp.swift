//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Sato: Starting...")
        print("🎯 Sato: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        // Kill any previously running instances of Sato so we never get
        // duplicate menu bar icons (e.g. login item + Xcode debug launch).
        terminateOtherRunningInstances()

        // Force accessory activation policy so macOS never shows the app
        // in the standard menu bar or dock — even when a panel becomes key.
        // Belt-and-suspenders with the Info.plist LSUIElement=YES setting,
        // which SwiftUI can sometimes override.
        NSApp.setActivationPolicy(.accessory)

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Sato: Registered as login item")
            } catch {
                print("⚠️ Sato: Failed to register as login item: \(error)")
            }
        }
    }

    /// Terminates any other running instances of this app so only one
    /// menu bar icon ever exists. Handles the case where a login-item
    /// instance is already running when Xcode launches a debug build,
    /// or vice versa.
    private func terminateOtherRunningInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for instance in runningInstances where instance.processIdentifier != currentPID {
            print("🎯 Sato: Terminating duplicate instance (PID \(instance.processIdentifier))")
            instance.terminate()
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Sato: Sparkle updater failed to start: \(error)")
        }
    }
}
