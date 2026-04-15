//
//  KeychainHelper.swift
//  leanring-buddy
//
//  Simple wrapper around the macOS Security framework for storing
//  and retrieving the user's Anthropic API key in the system Keychain.
//

import Foundation
import Security

enum KeychainHelper {

    private static let serviceName = "com.petGPT-companion.clicky"
    private static let anthropicAPIKeyAccount = "anthropic-api-key"

    static func saveAnthropicAPIKey(_ apiKey: String) {
        guard let data = apiKey.data(using: .utf8) else { return }

        // Delete any existing entry first to avoid errSecDuplicateItem
        deleteAnthropicAPIKey()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: anthropicAPIKeyAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ Keychain: Failed to save API key, status: \(status)")
        }
    }

    static func loadAnthropicAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: anthropicAPIKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8) else {
            return nil
        }

        return apiKey
    }

    static func deleteAnthropicAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: anthropicAPIKeyAccount
        ]

        SecItemDelete(query as CFDictionary)
    }
}
