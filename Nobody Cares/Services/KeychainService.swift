//
//  KeychainService.swift
//  Nobody Cares
//
//  Secure storage for device_token, session_token, and onboarding flags.
//  Uses kSecAttrAccessibleAfterFirstUnlock per spec.
//

import Foundation
import Security

enum KeychainKey: String, CaseIterable {
    case deviceToken      = "com.nobodycares.deviceToken"
    case sessionToken     = "com.nobodycares.sessionToken"
    case userId           = "com.nobodycares.userId"
    case username         = "com.nobodycares.username"
    case onboardingDone   = "com.nobodycares.onboardingDone"
    case appAttestKeyId   = "com.nobodycares.appAttestKeyId"
}

final class KeychainService {
    static let shared = KeychainService()
    private init() {}

    // MARK: - Public API

    /// Store a string value in the Keychain
    @discardableResult
    func set(_ value: String, for key: KeychainKey) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first
        delete(key)

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      key.rawValue,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve a string value from the Keychain
    func get(_ key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      key.rawValue,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Delete a value from the Keychain
    @discardableResult
    func delete(_ key: KeychainKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrAccount as String:  key.rawValue
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if a key exists
    func exists(_ key: KeychainKey) -> Bool {
        get(key) != nil
    }

    // MARK: - Convenience

    /// Wipe all app Keychain data (used on account deletion)
    func deleteAll() {
        for key in KeychainKey.allCases {
            delete(key)
        }
    }

    // MARK: - Static Convenience

    /// Static shorthand — set a value
    @discardableResult
    static func set(value: String, key: KeychainKey) -> Bool {
        shared.set(value, for: key)
    }

    /// Static shorthand — get a value
    static func get(key: KeychainKey) -> String? {
        shared.get(key)
    }

    /// Static shorthand — delete a value
    @discardableResult
    static func delete(key: KeychainKey) -> Bool {
        shared.delete(key)
    }
}
