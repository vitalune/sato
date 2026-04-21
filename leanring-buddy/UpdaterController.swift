//
//  UpdaterController.swift
//  leanring-buddy
//
//  Wraps Sparkle's SPUStandardUpdaterController so the rest of the app can
//  trigger update checks and observe readiness without importing Sparkle directly.
//
//  Implements SPUStandardUserDriverDelegate for "gentle reminders" — required
//  because Sato is a menu bar app (LSUIElement=true) and update dialogs would
//  otherwise appear behind the user's active window and get missed.
//

import AppKit
import Sparkle

@MainActor
final class UpdaterController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var updaterController: SPUStandardUpdaterController!

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    // MARK: - Gentle Reminders (SPUStandardUserDriverDelegate)

    /// Tells Sparkle we handle gentle scheduled update reminders, which prevents
    /// the console warning about background apps missing update notifications.
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    /// When Sparkle is ready to show an update dialog, temporarily switch from
    /// menu-bar-only (.accessory) to a regular app so the dialog appears in front
    /// and the user actually sees it.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// After the user interacts with the update prompt, return to menu-bar-only mode.
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Called when the update session finishes (installed, skipped, or dismissed).
    /// Ensures we always return to menu-bar-only mode even if the other callbacks
    /// didn't fire (e.g. user closed the window directly).
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
