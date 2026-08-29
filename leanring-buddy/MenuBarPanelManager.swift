//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    static let clickyPanelContentSizeChanged = Notification.Name("clickyPanelContentSizeChanged")
    static let clickyShowCustomSpritePicker = Notification.Name("clickyShowCustomSpritePicker")
    static let assistOverlayEnterPressed = Notification.Name("assistOverlayEnterPressed")
    static let assistOverlayCancelPressed = Notification.Name("assistOverlayCancelPressed")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var customSpritePickerPanel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var escapeKeyMonitor: Any?
    private var customSpritePickerClickOutsideMonitor: Any?
    private var customSpritePickerEscapeKeyMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var panelContentSizeObserver: NSObjectProtocol?
    private var showCustomSpritePickerObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let updaterController: UpdaterController
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380
    private let preferredCustomSpritePickerWidth: CGFloat = 560
    private let preferredCustomSpritePickerHeight: CGFloat = 620

    /// Window level above the sprite overlay (.screenSaver = 1000) so the
    /// panel renders on top of it and is always visible when opened.
    private let panelWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    init(companionManager: CompanionManager, updaterController: UpdaterController) {
        self.companionManager = companionManager
        self.updaterController = updaterController
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hidePanel()
                self?.hideCustomSpritePicker()
            }
        }

        panelContentSizeObserver = NotificationCenter.default.addObserver(
            forName: .clickyPanelContentSizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.positionPanelBelowStatusItem()
            }
        }

        showCustomSpritePickerObserver = NotificationCenter.default.addObserver(
            forName: .clickyShowCustomSpritePicker,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showCustomSpritePicker()
            }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = customSpritePickerClickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = customSpritePickerEscapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = panelContentSizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showCustomSpritePickerObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        let menuBarIcon = NSImage(named: "SatoMenuBarIcon")
        menuBarIcon?.isTemplate = true
        menuBarIcon?.size = NSSize(width: 20, height: 20)
        button.image = menuBarIcon
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        companionManager.prepareForMenuBarInteraction()
        guard !companionManager.isVisualRuntimePaused else { return }

        if let customSpritePickerPanel, customSpritePickerPanel.isVisible {
            hideCustomSpritePicker()
            return
        }

        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        guard !companionManager.isVisualRuntimePaused,
              !companionManager.isSleeping else {
            return
        }
        companionManager.setMenuBarPanelVisible(true)

        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        // Use orderFrontRegardless instead of makeKeyAndOrderFront to avoid
        // activating the app, which can cause a phantom app menu to appear
        // in the menu bar alongside our NSStatusItem. The panel still becomes
        // key (canBecomeKey=true) for text field input.
        panel?.orderFrontRegardless()
        panel?.makeKey()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
        if customSpritePickerPanel?.isVisible != true {
            companionManager.setMenuBarPanelVisible(false)
        }
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager, updaterController: updaterController)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = panelWindowLevel
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Custom Sprite Picker

    private func showCustomSpritePicker() {
        guard !companionManager.isVisualRuntimePaused,
              !companionManager.isSleeping else {
            return
        }
        hidePanel()
        companionManager.setMenuBarPanelVisible(
            true,
            showsPermissionControls: false
        )
        companionManager.petdexSpriteCatalog.prepareForPickerPresentation()

        if customSpritePickerPanel == nil {
            createCustomSpritePickerPanel(size: customSpritePickerSizeForCurrentScreen())
        }
        positionCustomSpritePickerBelowStatusItem()
        customSpritePickerPanel?.orderFrontRegardless()
        customSpritePickerPanel?.makeKey()
        installCustomSpritePickerDismissalMonitors()
    }

    private func hideCustomSpritePicker() {
        companionManager.cancelPendingPetdexSpriteSelection()
        customSpritePickerPanel?.orderOut(nil)
        customSpritePickerPanel?.contentView = nil
        customSpritePickerPanel = nil
        companionManager.petdexSpriteCatalog.cancelCatalogLoading()
        removeCustomSpritePickerDismissalMonitors()
        if panel?.isVisible != true {
            companionManager.setMenuBarPanelVisible(false)
        }
    }

    private func closeCustomSpritePickerAndReturnToMenu() {
        hideCustomSpritePicker()
        showPanel()
    }

    private func createCustomSpritePickerPanel(size: CGSize) {
        let customSpritePickerView = CustomSpritePickerView(
            companionManager: companionManager,
            onClose: { [weak self] in
                self?.closeCustomSpritePickerAndReturnToMenu()
            },
            onSelectionComplete: { [weak self] in
                self?.hideCustomSpritePicker()
            }
        )
        .frame(width: size.width, height: size.height)

        let hostingView = NSHostingView(rootView: customSpritePickerView)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: size.width,
            height: size.height
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let pickerPanel = KeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pickerPanel.isFloatingPanel = true
        pickerPanel.level = panelWindowLevel
        pickerPanel.isOpaque = false
        pickerPanel.backgroundColor = .clear
        pickerPanel.hasShadow = false
        pickerPanel.hidesOnDeactivate = false
        pickerPanel.isExcludedFromWindowsMenu = true
        pickerPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pickerPanel.isMovableByWindowBackground = false
        pickerPanel.titleVisibility = .hidden
        pickerPanel.titlebarAppearsTransparent = true
        pickerPanel.contentView = hostingView
        customSpritePickerPanel = pickerPanel
    }

    private func positionCustomSpritePickerBelowStatusItem() {
        guard let customSpritePickerPanel,
              let buttonWindow = statusItem?.button?.window else {
            return
        }

        let statusItemFrame = buttonWindow.frame
        let visibleScreenFrame = buttonWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? statusItemFrame
        let edgePadding: CGFloat = 8
        let panelWidth = customSpritePickerPanel.frame.width
        let panelHeight = customSpritePickerPanel.frame.height
        let unclampedOriginX = statusItemFrame.midX - (panelWidth / 2)
        let minimumOriginX = visibleScreenFrame.minX + edgePadding
        let maximumOriginX = visibleScreenFrame.maxX - panelWidth - edgePadding
        let panelOriginX = min(max(unclampedOriginX, minimumOriginX), maximumOriginX)
        let requestedOriginY = statusItemFrame.minY - panelHeight - 4
        let panelOriginY = max(requestedOriginY, visibleScreenFrame.minY + edgePadding)

        customSpritePickerPanel.setFrame(
            NSRect(
                x: panelOriginX,
                y: panelOriginY,
                width: panelWidth,
                height: panelHeight
            ),
            display: true
        )
    }

    private func customSpritePickerSizeForCurrentScreen() -> CGSize {
        let visibleScreenFrame = statusItem?.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(
                x: 0,
                y: 0,
                width: preferredCustomSpritePickerWidth,
                height: preferredCustomSpritePickerHeight
            )
        let totalEdgePadding: CGFloat = 16
        return CGSize(
            width: min(
                preferredCustomSpritePickerWidth,
                max(1, visibleScreenFrame.width - totalEdgePadding)
            ),
            height: min(
                preferredCustomSpritePickerHeight,
                max(1, visibleScreenFrame.height - totalEdgePadding)
            )
        )
    }

    private func installCustomSpritePickerDismissalMonitors() {
        removeCustomSpritePickerDismissalMonitors()

        customSpritePickerClickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self,
                  let customSpritePickerPanel = self.customSpritePickerPanel,
                  customSpritePickerPanel.isVisible,
                  !customSpritePickerPanel.frame.contains(NSEvent.mouseLocation) else {
                return
            }
            self.hideCustomSpritePicker()
        }

        customSpritePickerEscapeKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let customSpritePickerPanel = self?.customSpritePickerPanel,
                  customSpritePickerPanel.isVisible,
                  event.keyCode == 53 else {
                return event
            }
            self?.closeCustomSpritePickerAndReturnToMenu()
            return nil
        }
    }

    private func removeCustomSpritePickerDismissalMonitors() {
        if let customSpritePickerClickOutsideMonitor {
            NSEvent.removeMonitor(customSpritePickerClickOutsideMonitor)
            self.customSpritePickerClickOutsideMonitor = nil
        }
        if let customSpritePickerEscapeKeyMonitor {
            NSEvent.removeMonitor(customSpritePickerEscapeKeyMonitor)
            self.customSpritePickerEscapeKeyMonitor = nil
        }
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }

        // Dismiss the panel when the user presses Escape while it has focus.
        // Uses a local monitor because the panel can become key.
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if event.keyCode == 53 { // Escape
                self.hidePanel()
                return nil // Consume the event
            }
            return event
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }
}
