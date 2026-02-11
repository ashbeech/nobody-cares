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
    /// - Parameter captchaToken: Cloudflare Turnstile token (required to prevent bot sign-ups)
    func signInAnonymously(captchaToken: String? = nil) async throws {
        let session = try await supabase.auth.signInAnonymously(captchaToken: captchaToken)
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

    // MARK: - Sign Out (Account Deletion)

    /// Sign out and clear local auth state.
    /// After this, the anonymous identity is permanently lost.
    func signOut() async {
        try? await supabase.auth.signOut()
        isAuthenticated = false
        userId = nil
        username = nil
    }
}
