//
//  ContextManager.swift
//  leanring-buddy
//
//  Manages persistent Context Profiles that customize Sato's behavior.
//  Profiles are stored as JSON in ~/Library/Application Support/Sato/profiles.json.
//  Each profile contains plain-English instructions injected into the Claude system prompt.
//

import Combine
import Foundation

struct ContextProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var description: String
    var instructions: String
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date
}

@MainActor
final class ContextManager: ObservableObject {
    @Published var profiles: [ContextProfile] = []

    /// Maximum character count allowed for a profile's instructions field.
    static let maxInstructionsLength = 5000

    private static let applicationSupportDirectoryName = "Sato"
    private static let profilesFileName = "profiles.json"

    // MARK: - Initialization

    init() {
        loadProfiles()
    }

    // MARK: - Active Profile

    /// The currently active profile, if any.
    var activeProfile: ContextProfile? {
        profiles.first(where: { $0.isActive })
    }

    /// Sets the given profile as the only active profile.
    func setActiveProfile(_ profileID: UUID) {
        for index in profiles.indices {
            profiles[index].isActive = (profiles[index].id == profileID)
        }
        saveProfiles()
    }

    /// Deactivates all profiles.
    func deactivateAllProfiles() {
        for index in profiles.indices {
            profiles[index].isActive = false
        }
        saveProfiles()
    }

    // MARK: - CRUD

    func addProfile(name: String, description: String, instructions: String) {
        let trimmedInstructions = String(instructions.prefix(Self.maxInstructionsLength))
        let newProfile = ContextProfile(
            id: UUID(),
            name: name,
            description: description,
            instructions: trimmedInstructions,
            isActive: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        profiles.append(newProfile)
        saveProfiles()
    }

    func updateProfile(id: UUID, name: String, description: String, instructions: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmedInstructions = String(instructions.prefix(Self.maxInstructionsLength))
        profiles[index].name = name
        profiles[index].description = description
        profiles[index].instructions = trimmedInstructions
        profiles[index].updatedAt = Date()
        saveProfiles()
    }

    func deleteProfile(id: UUID) {
        profiles.removeAll(where: { $0.id == id })
        saveProfiles()
    }

    // MARK: - Persistence

    private static var profilesFileURL: URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let satoDirectory = applicationSupportDirectory.appendingPathComponent(applicationSupportDirectoryName)
        return satoDirectory.appendingPathComponent(profilesFileName)
    }

    private func ensureDirectoryExists() {
        let directoryURL = Self.profilesFileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func loadProfiles() {
        let fileURL = Self.profilesFileURL

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // First launch — create starter profiles
            profiles = Self.createStarterProfiles()
            saveProfiles()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            profiles = try decoder.decode([ContextProfile].self, from: data)
        } catch {
            print("⚠️ Sato: Failed to load profiles.json, recreating with defaults: \(error)")
            profiles = Self.createStarterProfiles()
            saveProfiles()
        }
    }

    private func saveProfiles() {
        ensureDirectoryExists()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(profiles)
            try data.write(to: Self.profilesFileURL, options: .atomic)
        } catch {
            print("⚠️ Sato: Failed to save profiles.json: \(error)")
        }
    }

    // MARK: - Starter Profiles

    private static func createStarterProfiles() -> [ContextProfile] {
        let now = Date()
        return [
            ContextProfile(
                id: UUID(),
                name: "General Assistant",
                description: "All-purpose helper",
                instructions: "I'm using Sato as a general desktop assistant. Help me with whatever I'm looking at on screen. Be concise and clear.",
                isActive: true,
                createdAt: now,
                updatedAt: now
            ),
            ContextProfile(
                id: UUID(),
                name: "Learning Mode",
                description: "Explain things like a teacher",
                instructions: "I'm using Sato to learn. When I ask about something on screen, explain it step by step like a patient teacher. Define any technical terms. Ask me if I understood.",
                isActive: false,
                createdAt: now,
                updatedAt: now
            ),
            ContextProfile(
                id: UUID(),
                name: "Code Review",
                description: "Review code on screen",
                instructions: "I'm a developer. When I show you code, review it for bugs, style issues, and potential improvements. Be direct and specific. Reference line numbers when visible.",
                isActive: false,
                createdAt: now,
                updatedAt: now
            )
        ]
    }
}
