//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures the Ctrl+Option keyboard shortcut while the app is running in the
//  background. Uses a listen-only CGEvent tap so modifier-based shortcuts
//  are detected reliably system-wide.
//
//  Detects Ctrl+Option press/release transitions for the assist flow.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

/// Shortcut transition states for the Ctrl+Option hotkey.
enum ShortcutTransition {
    case pressed
    case released
    case none
}

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    /// Publisher for Ctrl+Option press/release transitions.
    let shortcutTransitionPublisher = PassthroughSubject<ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let shortcutTransition = Self.detectShortcutTransition(
            eventType: eventType,
            event: event,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }

    /// Determines the Ctrl+Option shortcut transition based on the current event.
    /// Returns `.pressed` when both Ctrl and Option are held down, `.released`
    /// when they were previously pressed and at least one is now released.
    private static func detectShortcutTransition(
        eventType: CGEventType,
        event: CGEvent,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard eventType == .flagsChanged else { return .none }

        let flags = event.flags
        let controlPressed = flags.contains(.maskControl)
        let optionPressed = flags.contains(.maskAlternate)
        let bothPressed = controlPressed && optionPressed

        if bothPressed && !wasShortcutPreviouslyPressed {
            return .pressed
        } else if !bothPressed && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}
