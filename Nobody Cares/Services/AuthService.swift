//
//  AuthService.swift
//  Nobody Cares
//
//  Handles device-linked anonymous identity via Supabase Auth.
//  No login, no logout, no email, no password. Identity is the device.
//

import Foundation
import Supabase

// MARK: - RPC Parameter / Response Types

private struct RegisterUserParams: Encodable {
    let lat: Double?
    let lng: Double?
}

private struct UsernameResponse: Decodable {
    let outUsername: String

    enum CodingKeys: String, CodingKey {
        case outUsername = "out_username"
    }
}

// MARK: - Auth Service

@Observable
final class AuthService {
    var isAuthenticated = false
    var userId: UUID?
    var username: String?
    var isLoading = false
    var error: String?

    // MARK: - Initialize (App Launch)

    /// Check for an existing Supabase session.
    /// If found, user is already authenticated — fetch their profile.
    func initialize() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let session = try await supabase.auth.session
            isAuthenticated = true
            userId = session.user.id
            await fetchProfile()
        } catch {
            // No existing session — new device or session expired
            isAuthenticated = false
            userId = nil
            username = nil
        }
    }

    // MARK: - Anonymous Sign-In (Onboarding)

    /// Create an anonymous auth session. Called once during onboarding.
    /// The Supabase SDK persists the session in Keychain automatically.
    /// Bot prevention is handled by App Attest (device attestation), not CAPTCHA.
    func signInAnonymously() async throws {
        let session = try await supabase.auth.signInAnonymously()
        isAuthenticated = true
        userId = session.user.id
    }

    // MARK: - Register User Profile

    /// Create the user row in the `users` table with location and generated username.
    /// Idempotent — returns existing username if already registered.
    func registerUser(latitude: Double?, longitude: Double?) async throws {
        let params = RegisterUserParams(lat: latitude, lng: longitude)

        let result: [UsernameResponse] = try await supabase
            .rpc("register_user", params: params)
            .execute()
            .value

        if let name = result.first?.outUsername {
            username = name
        }
    }

    // MARK: - Fetch Profile

    /// Fetch the user's profile (username) from the `users` table.
    func fetchProfile() async {
        guard let userId else { return }

        struct Profile: Decodable {
            let username: String
        }

        do {
            let profile: Profile = try await supabase
                .from("users")
                .select("username")
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value

            username = profile.username
        } catch {
            self.error = "Failed to load identity"
        }
    }

    // MARK: - Regenerate Username

    /// Generate a new random username, freeing the old one.
    func regenerateUsername() async throws {
        let result: [UsernameResponse] = try await supabase
            .rpc("regenerate_username")
            .execute()
            .value

        if let name = result.first?.outUsername {
            username = name
        }
    }

    // MARK: - Delete Account (Hard Delete)

    /// Delete the account and ALL associated data from the server.
    ///
    /// This calls the `delete-account` Edge Function which:
    ///   1. Cascade-deletes every DB row (content, views, reports, blocks, etc.)
    ///   2. Purges all uploaded files from Storage
    ///   3. Deletes the Supabase Auth user
    ///
    /// The operation is irreversible. The anonymous identity is permanently lost.
    ///
    /// - Parameter appAttest: Used to sign the request with a device assertion,
    ///   preventing account deletion via a stolen JWT.
    func deleteAccount(appAttest: AppAttestService) async throws {
        let body = DeleteAccountBody(confirmation: "DELETE_MY_ACCOUNT")

        // Generate assertion headers
        let bodyData = try JSONEncoder().encode(body)
        var headers: [String: String] = [:]
        if let assertionB64 = await appAttest.assertionHeader(for: bodyData),
           let keyId = appAttest.keyId {
            headers["X-App-Assertion"] = assertionB64
            headers["X-App-KeyId"] = keyId
        }

        let response: DeleteAccountResponse = try await supabase.functions
            .invoke("delete-account", options: .init(headers: headers, body: body))

        guard response.deleted == true else {
            throw AuthServiceError.deletionFailed(response.error ?? "Unknown error")
        }

        // Clear local auth state
        try? await supabase.auth.signOut()
        isAuthenticated = false
        userId = nil
        username = nil

        // Wipe all Keychain data (session, attestation key, etc.)
        KeychainService.shared.deleteAll()
    }

    // MARK: - Sign Out (Local Only)

    /// Sign out and clear local auth state.
    /// After this, the anonymous identity is permanently lost locally,
    /// but server data is NOT deleted. Use `deleteAccount()` for full deletion.
    func signOut() async {
        try? await supabase.auth.signOut()
        isAuthenticated = false
        userId = nil
        username = nil
    }
}

// MARK: - Delete Account Types

private struct DeleteAccountBody: Encodable {
    let confirmation: String
}

private struct DeleteAccountResponse: Decodable {
    let deleted: Bool?
    let error: String?
}

// MARK: - Auth Service Errors

enum AuthServiceError: Error, LocalizedError {
    case deletionFailed(String)

    var errorDescription: String? {
        switch self {
        case .deletionFailed(let reason):
            return "Account deletion failed: \(reason)"
        }
    }
}
