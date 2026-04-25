//
//  KeychainHelper.swift
//  leanring-buddy
//
//  Wrapper around the macOS Security framework for storing and retrieving
//  API keys for multiple AI providers in the system Keychain.
//

import Foundation
import Security

enum KeychainProvider: String, CaseIterable {
    case anthropic = "anthropic-api-key"
    case openai = "openai-api-key"
    case ollamaCloud = "ollama-cloud-api-key"
}

enum KeychainHelper {

    private static let serviceName = "com.petGPT-companion.clicky"

    // MARK: - Multi-Provider API

    static func saveAPIKey(_ apiKey: String, for provider: KeychainProvider) {
        guard let data = apiKey.data(using: .utf8) else { return }

        deleteAPIKey(for: provider)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: provider.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ Keychain: Failed to save \(provider.rawValue) key, status: \(status)")
        }
    }

    static func loadAPIKey(for provider: KeychainProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return apiKey
    }

    static func deleteAPIKey(for provider: KeychainProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: provider.rawValue,
        ]

        SecItemDelete(query as CFDictionary)
    }

    static func hasAPIKey(for provider: KeychainProvider) -> Bool {
        loadAPIKey(for: provider) != nil
    }

    // MARK: - Legacy Anthropic Convenience (keeps existing call sites working during migration)

    static func saveAnthropicAPIKey(_ apiKey: String) {
        saveAPIKey(apiKey, for: .anthropic)
    }

    static func loadAnthropicAPIKey() -> String? {
        loadAPIKey(for: .anthropic)
    }

    static func deleteAnthropicAPIKey() {
        deleteAPIKey(for: .anthropic)
    }
}
