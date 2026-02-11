//
//  SupabaseManager.swift
//  Nobody Cares
//
//  Global Supabase client with Keychain-backed auth session storage.
//
//  Credentials are loaded from Config/Secrets.swift (gitignored).
//  See Secrets.swift.example in the project root for setup instructions.
//

import Foundation
import Security
import Supabase

// MARK: - Shared Client

/// Global Supabase client — the single entry point for all backend operations.
/// Uses the publishable key (replaces legacy "anon" key) from the gitignored Secrets file.
let supabase = SupabaseClient(
    supabaseURL: URL(string: Secrets.supabaseURL)!,
    supabaseKey: Secrets.supabasePublishableKey,
    options: .init(
        auth: .init(
            storage: SupabaseKeychainStorage()
        )
    )
)

// MARK: - Keychain Auth Storage

/// Stores Supabase auth sessions in iOS Keychain (encrypted at rest)
/// instead of the default UserDefaults. Per spec: kSecAttrAccessibleAfterFirstUnlock.
struct SupabaseKeychainStorage: AuthLocalStorage, Sendable {
    private let prefix = "com.nobodycares.supabase."

    func store(key: String, value: Data) throws {
        let account = prefix + key

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Store new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SupabaseKeychainError.storeFailed(status)
        }
    }

    func retrieve(key: String) throws -> Data? {
        let account = prefix + key
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SupabaseKeychainError.retrieveFailed(status)
        }

        return result as? Data
    }

    func remove(key: String) throws {
        let account = prefix + key
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SupabaseKeychainError.removeFailed(status)
        }
    }
}

enum SupabaseKeychainError: Error {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case removeFailed(OSStatus)
}
