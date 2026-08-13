//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    let updaterController: UpdaterController
    @State private var emailInput: String = ""

    // MARK: - Context Profile Editor State
    @State private var isEditingProfile: Bool = false
    @State private var editingProfileID: UUID? = nil
    @State private var profileNameInput: String = ""
    @State private var profileDescriptionInput: String = ""
    @State private var profileInstructionsInput: String = ""
    @State private var profileUseOverride: Bool = false
    @State private var profileOverrideProviderID: String = "anthropic"
    @State private var profileOverrideModelID: String = AnthropicProvider.defaultModelID
    @State private var panelOpacity: Double = 0

    // Tracks whether the user has already clicked "Grant" for Screen Recording,
    // so the button can switch to "Quit & Relaunch" (macOS requires a restart
    // for Screen Recording permission changes to take effect).
    @State private var hasClickedScreenRecordingGrant: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                modelPickerRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 8)

                spritePickerRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 8)

                LocalSpeechSettingsRow(
                    speechTranscriptionManager: companionManager.localSpeechTranscriptionManager
                )
                .padding(.horizontal, 16)

                sectionDivider
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 8)

                stealthModeToggleRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 8)

                alwaysChatSidebarToggleRow
                    .padding(.horizontal, 16)

                sectionDivider

                contextProfilesSection
                    .padding(.horizontal, 16)

                sectionDivider

                conversationSection
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 8)

                hotkeyLabelsSection
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 16)

                dmFarzaButton
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 8)

                checkForUpdatesButton
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
        .opacity(panelOpacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.15)) {
                panelOpacity = 1.0
            }
        }
    }

    /// Thin gray divider with padding between config sections.
    private var sectionDivider: some View {
        Divider()
            .background(DS.Colors.borderSubtle.opacity(0.5))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Sato")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Sato.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text(revokedPermissionsMessage)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Sato.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Sato is a desktop AI companion that helps you with whatever is on your screen.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Sato only takes a screenshot when you press the hotkey. Grant the permissions below to get started.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var revokedPermissionsMessage: String {
        var revokedCount = 0
        if !companionManager.hasAccessibilityPermission { revokedCount += 1 }
        if !companionManager.hasScreenRecordingPermission { revokedCount += 1 }
        if companionManager.hasScreenRecordingPermission && !companionManager.hasScreenContentPermission {
            revokedCount += 1
        }

        if revokedCount == 1 {
            return "One permission was revoked. Grant it below to keep using Sato."
        } else {
            return "Some permissions were revoked. Grant them below to keep using Sato."
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Button(action: {
                        companionManager.submitEmail(emailInput)
                    }) {
                        Text("Submit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accent.opacity(0.4)
                                          : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text("Start")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    if isGranted {
                        Text("Only takes a screenshot when you use the hotkey")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    } else if hasClickedScreenRecordingGrant {
                        Text("After enabling in Settings, click Quit & Relaunch")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    } else {
                        Text("Requires app restart after granting")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else if hasClickedScreenRecordingGrant {
                Button(action: {
                    quitAndRelaunch()
                }) {
                    Text("Quit & Relaunch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            } else {
                Button(action: {
                    WindowPositionManager.requestScreenRecordingPermission()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        hasClickedScreenRecordingGrant = true
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func quitAndRelaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1 && open \"\(bundlePath)\""]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Stealth Mode Toggle

    private var stealthModeToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Stealth Mode")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isStealthModeEnabled },
                set: { companionManager.setStealthModeEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var alwaysChatSidebarToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Always Open Chat")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.alwaysOpenChatSidebar },
                set: { companionManager.setAlwaysOpenChatSidebar($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        aiModelSection
    }

    // MARK: - AI Model Section (Multi-Provider)

    @ViewBuilder
    private var aiModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI MODEL")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            // Provider segmented picker
            HStack(spacing: 0) {
                providerOptionButton(label: "Anthropic", providerID: "anthropic")
                providerOptionButton(label: "OpenAI", providerID: "openai")
                providerOptionButton(label: "Ollama", providerID: "ollama")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )

            // Provider-specific settings
            switch companionManager.providerManager.selectedProviderID {
            case "openai":
                openAISettingsSection
            case "ollama", "ollama-local", "ollama-cloud":
                ollamaSettingsSection
            default:
                anthropicSettingsSection
            }
        }
        .padding(.vertical, 4)
    }

    private func providerOptionButton(label: String, providerID: String) -> some View {
        let selectedID = companionManager.providerManager.selectedProviderID
        let isSelected: Bool
        if providerID == "ollama" {
            isSelected = selectedID == "ollama-local" || selectedID == "ollama-cloud"
        } else {
            isSelected = selectedID == providerID
        }

        return Button(action: {
            if providerID == "ollama" {
                // Default to local Ollama when clicking the Ollama tab
                let currentOllamaMode = (selectedID == "ollama-local" || selectedID == "ollama-cloud") ? selectedID : ollamaMode
                companionManager.providerManager.selectedProviderID = currentOllamaMode
                companionManager.providerManager.refreshOllamaLocalStatus()
            } else {
                companionManager.providerManager.selectedProviderID = providerID
            }
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Anthropic Settings

    private var anthropicSettingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            providerAPIKeyField(
                label: "Anthropic API Key",
                placeholder: "sk-ant-...",
                hasKey: companionManager.hasAnthropicAPIKey,
                onSave: { companionManager.saveAnthropicAPIKey($0) }
            )

            HStack {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                HStack(spacing: 0) {
                    ForEach(AnthropicProvider.availableModels, id: \.id) { model in
                        anthropicModelButton(model: model)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }
        }
    }

    private func anthropicModelButton(model: AnthropicModel) -> some View {
        let isSelected = companionManager.providerManager.anthropicModelID == model.id
        // Short label: strip "Claude " prefix for compact display
        let shortLabel = model.displayName.replacingOccurrences(of: "Claude ", with: "")
        return Button(action: {
            companionManager.providerManager.anthropicModelID = model.id
        }) {
            Text(shortLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - OpenAI Settings

    private var openAISettingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            providerAPIKeyField(
                label: "OpenAI API Key",
                placeholder: "sk-...",
                hasKey: companionManager.hasOpenAIAPIKey,
                onSave: { companionManager.saveOpenAIAPIKey($0) }
            )

            HStack {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                HStack(spacing: 0) {
                    ForEach(OpenAIProvider.availableModels, id: \.id) { model in
                        openAIModelButton(model: model)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }
        }
    }

    private func openAIModelButton(model: OpenAIModel) -> some View {
        let isSelected = companionManager.providerManager.openAIModelID == model.id
        return Button(action: {
            companionManager.providerManager.openAIModelID = model.id
        }) {
            Text(model.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Ollama Settings

    @State private var ollamaMode: String = UserDefaults.standard.string(forKey: "selectedProvider")?.hasPrefix("ollama") == true
        ? (UserDefaults.standard.string(forKey: "selectedProvider") ?? "ollama-local")
        : "ollama-local"

    private var ollamaSettingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Local / Cloud picker
            HStack {
                Text("Mode")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                HStack(spacing: 0) {
                    ollamaModeButton(label: "Local", modeID: "ollama-local")
                    ollamaModeButton(label: "Cloud", modeID: "ollama-cloud")
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }

            if ollamaMode == "ollama-local" {
                ollamaLocalSettingsSection
            } else {
                ollamaCloudSettingsSection
            }
        }
    }

    private func ollamaModeButton(label: String, modeID: String) -> some View {
        let isSelected = ollamaMode == modeID
        return Button(action: {
            ollamaMode = modeID
            companionManager.providerManager.selectedProviderID = modeID
            if modeID == "ollama-local" {
                companionManager.providerManager.refreshOllamaLocalStatus()
            }
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var ollamaLocalSettingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(companionManager.providerManager.ollamaLocalIsReachable ? DS.Colors.success : Color.red.opacity(0.7))
                    .frame(width: 6, height: 6)

                if companionManager.providerManager.ollamaLocalIsReachable {
                    Text("Ollama running")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                } else {
                    Text("Start Ollama to use local models")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.red.opacity(0.7))
                }

                Spacer()

                Button(action: {
                    companionManager.providerManager.refreshOllamaLocalStatus()
                }) {
                    Text("Check")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if companionManager.providerManager.ollamaLocalIsReachable && !companionManager.providerManager.ollamaLocalModels.isEmpty {
                // Model picker dropdown
                HStack {
                    Text("Model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    Picker("", selection: Binding(
                        get: { companionManager.providerManager.ollamaLocalModelName },
                        set: { companionManager.providerManager.ollamaLocalModelName = $0 }
                    )) {
                        ForEach(companionManager.providerManager.ollamaLocalModels) { model in
                            HStack {
                                Text(model.name)
                                if model.supportsVision {
                                    Text("Vision")
                                        .font(.system(size: 9))
                                        .foregroundColor(DS.Colors.accent)
                                }
                            }
                            .tag(model.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                }
            }
        }
        .onAppear {
            companionManager.providerManager.refreshOllamaLocalStatus()
        }
    }

    private var ollamaCloudSettingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            providerAPIKeyField(
                label: "Ollama Cloud API Key",
                placeholder: "API key from ollama.com",
                hasKey: companionManager.hasOllamaCloudAPIKey,
                onSave: { companionManager.saveOllamaCloudAPIKey($0) }
            )

            HStack {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Text(OllamaCloudProvider.availableModels.first?.displayName ?? OllamaCloudProvider.defaultModelID)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    )
            }
        }
    }

    // MARK: - Shared API Key Field

    @State private var providerKeyInput: String = ""
    @State private var isProviderKeyVisible: Bool = false

    private func providerAPIKeyField(
        label: String,
        placeholder: String,
        hasKey: Bool,
        onSave: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                if hasKey {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(DS.Colors.success)
                            .frame(width: 6, height: 6)
                        Text("Saved")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.success)
                    }
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red.opacity(0.7))
                            .frame(width: 6, height: 6)
                        Text("Not Set")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.red.opacity(0.7))
                    }
                }
            }

            HStack(spacing: 6) {
                ZStack {
                    if isProviderKeyVisible {
                        TextField(placeholder, text: $providerKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(DS.Colors.textPrimary)
                    } else {
                        SecureField(placeholder, text: $providerKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

                Button(action: {
                    isProviderKeyVisible.toggle()
                }) {
                    Image(systemName: isProviderKeyVisible ? "eye.slash" : "eye")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: {
                    onSave(providerKeyInput)
                    providerKeyInput = ""
                }) {
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(providerKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      ? DS.Colors.accent.opacity(0.4)
                                      : DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(providerKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Sprite Picker

    private var spritePickerRow: some View {
        HStack {
            Text("Sprite")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                spriteOptionButton(label: "Max", directoryName: "max-animations")
                spriteOptionButton(label: "Sky", directoryName: "sky-animations")
                spriteOptionButton(label: "Lexi", directoryName: "lexi-animations")
                spriteOptionButton(label: "Rover", directoryName: "rover-animations")
                spriteOptionButton(label: "Paris", directoryName: "paris-animations")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func spriteOptionButton(label: String, directoryName: String) -> some View {
        let isSelected = companionManager.spriteAnimationManager.activeSpriteDirectory == directoryName
        return Button(action: {
            companionManager.spriteAnimationManager.switchSpriteAssets(directoryName: directoryName)
            UserDefaults.standard.set(directoryName, forKey: "activeSpriteDirectory")
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - API Key

    // MARK: - Context Profiles

    private var contextProfilesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CONTEXT PROFILES")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            // Active profile indicator
            if let activeProfile = companionManager.contextManager.activeProfile {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Active: \(activeProfile.name)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Text("No active profile")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            if isEditingProfile {
                profileEditorView
            } else {
                profileListView
            }
        }
    }

    private var profileListView: some View {
        VStack(spacing: 4) {
            ForEach(companionManager.contextManager.profiles) { profile in
                profileRow(profile: profile)
            }

            Button(action: {
                editingProfileID = nil
                profileNameInput = ""
                profileDescriptionInput = ""
                profileInstructionsInput = ""
                profileUseOverride = false
                profileOverrideProviderID = "anthropic"
                profileOverrideModelID = AnthropicProvider.defaultModelID
                isEditingProfile = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text("New Profile")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private func profileRow(profile: ContextProfile) -> some View {
        HStack(spacing: 8) {
            // Radio indicator
            Button(action: {
                companionManager.contextManager.setActiveProfile(profile.id)
            }) {
                Image(systemName: profile.isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(profile.isActive ? DS.Colors.success : DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            // Name + description
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(profile.description)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            // Edit button
            Button(action: {
                editingProfileID = profile.id
                profileNameInput = profile.name
                profileDescriptionInput = profile.description
                profileInstructionsInput = profile.instructions
                profileUseOverride = profile.overrideProviderID != nil
                profileOverrideProviderID = profile.overrideProviderID ?? "anthropic"
                profileOverrideModelID = profile.overrideModelID ?? AnthropicProvider.defaultModelID
                isEditingProfile = true
            }) {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            // Delete button
            Button(action: {
                companionManager.contextManager.deleteProfile(id: profile.id)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(profile.isActive ? Color.white.opacity(0.06) : Color.clear)
        )
    }

    private var profileEditorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Profile Name", text: $profileNameInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

            TextField("Description", text: $profileDescriptionInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

            VStack(alignment: .trailing, spacing: 2) {
                TextEditor(text: $profileInstructionsInput)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80, maxHeight: 120)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                    .overlay(alignment: .topLeading) {
                        if profileInstructionsInput.isEmpty {
                            Text("Tell Sato what you're working on, how you'd like responses, and anything it should keep in mind. Write in plain English — no special formatting needed.")
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textTertiary.opacity(0.6))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: profileInstructionsInput) { _, newValue in
                        if newValue.count > ContextManager.maxInstructionsLength {
                            profileInstructionsInput = String(newValue.prefix(ContextManager.maxInstructionsLength))
                        }
                    }

                Text("\(profileInstructionsInput.count)/\(ContextManager.maxInstructionsLength)")
                    .font(.system(size: 10))
                    .foregroundColor(
                        profileInstructionsInput.count > ContextManager.maxInstructionsLength - 200
                            ? Color.orange
                            : DS.Colors.textTertiary
                    )
            }

            // AI Model Override
            VStack(alignment: .leading, spacing: 4) {
                Text("AI MODEL OVERRIDE")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)

                Toggle(isOn: $profileUseOverride) {
                    Text("Use a specific model for this profile")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .toggleStyle(.switch)
                .tint(DS.Colors.accent)
                .scaleEffect(0.8, anchor: .leading)

                if profileUseOverride {
                    HStack {
                        Text("Provider")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)

                        Spacer()

                        Picker("", selection: $profileOverrideProviderID) {
                            Text("Anthropic").tag("anthropic")
                            Text("OpenAI").tag("openai")
                            Text("Ollama Local").tag("ollama-local")
                            Text("Ollama Cloud").tag("ollama-cloud")
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 150)
                        .onChange(of: profileOverrideProviderID) { _, newProviderID in
                            profileOverrideModelID = defaultModelForProvider(newProviderID)
                        }
                    }

                    HStack {
                        Text("Model")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)

                        Spacer()

                        Picker("", selection: $profileOverrideModelID) {
                            ForEach(modelsForProvider(profileOverrideProviderID), id: \.self) { modelID in
                                Text(displayNameForModel(modelID, provider: profileOverrideProviderID))
                                    .tag(modelID)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 150)
                    }
                }
            }

            HStack {
                Button(action: {
                    isEditingProfile = false
                    editingProfileID = nil
                }) {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Spacer()

                Button(action: {
                    saveProfileFromEditor()
                }) {
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(profileNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      ? DS.Colors.accent.opacity(0.4)
                                      : DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(profileNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func modelsForProvider(_ providerID: String) -> [String] {
        switch providerID {
        case "openai": return OpenAIProvider.availableModels.map(\.id)
        case "ollama-local": return companionManager.providerManager.ollamaLocalModels.map(\.name)
        case "ollama-cloud": return OllamaCloudProvider.availableModels.map(\.id)
        default: return AnthropicProvider.availableModels.map(\.id)
        }
    }

    private func defaultModelForProvider(_ providerID: String) -> String {
        switch providerID {
        case "openai": return OpenAIProvider.defaultModelID
        case "ollama-cloud": return OllamaCloudProvider.defaultModelID
        case "ollama-local": return companionManager.providerManager.ollamaLocalModels.first?.name ?? ""
        default: return AnthropicProvider.defaultModelID
        }
    }

    private func displayNameForModel(_ modelID: String, provider: String) -> String {
        switch provider {
        case "openai":
            return OpenAIProvider.availableModels.first(where: { $0.id == modelID })?.displayName ?? modelID
        case "anthropic":
            return AnthropicProvider.availableModels.first(where: { $0.id == modelID })?.displayName ?? modelID
        case "ollama-cloud":
            return OllamaCloudProvider.availableModels.first(where: { $0.id == modelID })?.displayName ?? modelID
        default:
            return modelID
        }
    }

    private func saveProfileFromEditor() {
        let trimmedName = profileNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let overrideProvider = profileUseOverride ? profileOverrideProviderID : nil
        let overrideModel = profileUseOverride ? profileOverrideModelID : nil

        if let existingID = editingProfileID {
            companionManager.contextManager.updateProfile(
                id: existingID,
                name: trimmedName,
                description: profileDescriptionInput.trimmingCharacters(in: .whitespacesAndNewlines),
                instructions: profileInstructionsInput,
                overrideProviderID: overrideProvider,
                overrideModelID: overrideModel
            )
        } else {
            companionManager.contextManager.addProfile(
                name: trimmedName,
                description: profileDescriptionInput.trimmingCharacters(in: .whitespacesAndNewlines),
                instructions: profileInstructionsInput,
                overrideProviderID: overrideProvider,
                overrideModelID: overrideModel
            )
        }

        isEditingProfile = false
        editingProfileID = nil
    }

    // MARK: - Conversation History

    private var conversationSection: some View {
        PreviousConversationsSection(
            conversationStore: companionManager.conversationStore,
            onOpenConversation: { conversationID in
                companionManager.openSavedConversation(conversationID: conversationID)
            },
            onSetConversationPinned: { conversationID, isPinned in
                companionManager.setConversationPinned(
                    conversationID: conversationID,
                    isPinned: isPinned
                )
            }
        )
    }

    // MARK: - Hotkey Labels

    private var hotkeyLabelsSection: some View {
        VStack(spacing: 4) {
            hotkeyLabelRow(actionName: "Ask", shortcut: "Ctrl + Option")
            hotkeyLabelRow(
                actionName: "Voice in prompt",
                shortcut: LocalSpeechInputButton.keyboardShortcutDescription
            )
        }
    }

    private func hotkeyLabelRow(actionName: String, shortcut: String) -> some View {
        HStack {
            Text(actionName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Spacer()

            Text(shortcut)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        }
    }

    // MARK: - DM Farza Button

    private var dmFarzaButton: some View {
        Button(action: {
            if let url = URL(string: "https://github.com/vitalune/sato/issues") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Got feedback?")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Bugs, ideas, feature requests — open an issue on GitHub.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Check for Updates

    private var checkForUpdatesButton: some View {
        Button(action: {
            updaterController.checkForUpdates()
        }) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .medium))
                Text("Check for Updates")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!updaterController.canCheckForUpdates)
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: {
                    NSApp.terminate(nil)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .medium))
                        Text("Quit Sato")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()

                if companionManager.hasCompletedOnboarding {
                    Spacer()

                    Button(action: {
                        companionManager.replayOnboarding()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle")
                                .font(.system(size: 11, weight: .medium))
                            Text("Watch Onboarding Again")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            VStack(spacing: 2) {
                Text("Sato — Your AI Desktop Companion")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary.opacity(0.6))
                Text("Created by Amir Valizadeh")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(DS.Colors.textTertiary.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        return DS.Colors.success
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        return "Active"
    }

}

private struct PreviousConversationsSection: View {
    @ObservedObject var conversationStore: ConversationStore
    let onOpenConversation: (UUID) -> Void
    let onSetConversationPinned: (UUID, Bool) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 6) {
            Button {
                isExpanded.toggle()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .clickyPanelContentSizeChanged,
                        object: nil
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text("Previous Conversations")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    if !conversationStore.conversationsForMenu.isEmpty {
                        Text("\(conversationStore.conversationsForMenu.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                if conversationStore.conversationsForMenu.isEmpty {
                    Text("Your recent conversations will appear here.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(conversationStore.conversationsForMenu) { conversation in
                                PreviousConversationRow(
                                    conversation: conversation,
                                    onOpenConversation: {
                                        onOpenConversation(conversation.id)
                                    },
                                    onSetPinned: { isPinned in
                                        onSetConversationPinned(
                                            conversation.id,
                                            isPinned
                                        )
                                    }
                                )
                            }
                        }
                    }
                    .frame(
                        height: min(
                            CGFloat(conversationStore.conversationsForMenu.count) * 58,
                            196
                        )
                    )
                }
            }
        }
    }
}

private struct PreviousConversationRow: View {
    let conversation: SavedConversation
    let onOpenConversation: () -> Void
    let onSetPinned: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpenConversation) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(conversation.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)

                        Text(conversation.updatedAt, style: .relative)
                            .font(.system(size: 9))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }

                    Text(conversation.latestAssistantResponse ?? "No response saved")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button {
                onSetPinned(!conversation.isPinned)
            } label: {
                Image(systemName: conversation.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(
                        conversation.isPinned
                            ? DS.Colors.accentText
                            : DS.Colors.textTertiary
                    )
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(conversation.isPinned ? "Unpin conversation" : "Pin conversation")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(isHovered ? DS.Colors.surface3 : DS.Colors.surface2.opacity(0.65))
        )
        .onHover { isHovered = $0 }
    }
}
