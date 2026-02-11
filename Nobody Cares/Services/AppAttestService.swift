//
//  AppAttestService.swift
//  Nobody Cares
//
//  Apple App Attest — cryptographic proof that API requests come from
//  a genuine copy of this app running on real Apple hardware.
//
//  Layer 1 of the anti-abuse system:
//  - Attestation: happens once at registration, proves app legitimacy
//  - Assertion: happens on every sensitive request, signs the request data
//
//  Bots, scripts, and modified app binaries cannot produce valid attestations.
//  Simulators/jailbroken devices also fail, so we include a dev bypass.
//

import Foundation
import DeviceCheck
import CryptoKit

// MARK: - App Attest Service

@Observable
final class AppAttestService {

    /// The hardware-backed key identifier (persisted in Keychain)
    var keyId: String?

    /// Whether App Attest is supported on this device
    var isSupported: Bool {
        DCAppAttestService.shared.isSupported
    }

    /// Whether we have a valid attestation
    var isAttested: Bool {
        keyId != nil && hasStoredAttestation
    }

    private var hasStoredAttestation = false
    private let keychainKey = "com.nobodycares.appattest.keyid"

    // MARK: - Initialize

    /// Load existing key ID from Keychain on app launch.
    func initialize() {
        if let stored = KeychainService.get(key: .appAttestKeyId) {
            keyId = stored
            hasStoredAttestation = true
        }
    }

    // MARK: - Generate Key

    /// Generate a hardware-backed cryptographic key for App Attest.
    /// Call this during registration, before attestation.
    func generateKey() async throws -> String {
        let service = DCAppAttestService.shared

        guard service.isSupported else {
            throw AppAttestError.notSupported
        }

        let generatedKeyId = try await service.generateKey()

        // Persist key ID
        KeychainService.set(value: generatedKeyId, key: .appAttestKeyId)
        await MainActor.run {
            keyId = generatedKeyId
        }

        return generatedKeyId
    }

    // MARK: - Attest Key

    /// Attest the key with Apple. This proves the key was generated
    /// on genuine Apple hardware running your real app binary.
    ///
    /// The attestation object is sent to our server (Edge Function)
    /// which verifies it with Apple and stores the result.
    ///
    /// - Parameter challenge: Server-provided challenge (nonce)
    /// - Returns: The raw attestation data to send to the server
    func attestKey(challenge: Data) async throws -> Data {
        guard let keyId else {
            throw AppAttestError.noKeyGenerated
        }

        let service = DCAppAttestService.shared

        // Hash the challenge to create the clientDataHash
        let clientDataHash = Data(SHA256.hash(data: challenge))

        let attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
        return attestation
    }

    // MARK: - Generate Assertion

    /// Generate a signed assertion for an API request.
    /// This is attached to every sensitive request as proof of legitimacy.
    ///
    /// - Parameter requestData: The request payload to sign (typically a hash of the request)
    /// - Returns: The assertion data to include in the request header
    func generateAssertion(for requestData: Data) async throws -> Data {
        guard let keyId else {
            throw AppAttestError.noKeyGenerated
        }

        let service = DCAppAttestService.shared

        // Hash the request data
        let clientDataHash = Data(SHA256.hash(data: requestData))

        let assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
        return assertion
    }

    // MARK: - Full Attestation Flow

    /// Complete attestation flow: generate key → get challenge → attest → verify server-side.
    /// Called once during onboarding/registration.
    func performAttestation() async throws {
        guard isSupported else {
            // Simulator or unsupported device — skip in debug
            #if DEBUG
            print("[AppAttest] Skipping attestation — not supported (simulator/debug)")
            return
            #else
            throw AppAttestError.notSupported
            #endif
        }

        // 1. Generate key
        let newKeyId = try await generateKey()

        // 2. Get challenge from server
        let challenge = try await fetchAttestationChallenge()

        // 3. Attest with Apple
        let attestation = try await attestKey(challenge: challenge)

        // 4. Send attestation to server for verification
        try await verifyAttestationOnServer(
            keyId: newKeyId,
            attestation: attestation,
            challenge: challenge
        )

        await MainActor.run {
            hasStoredAttestation = true
        }
    }

    // MARK: - Server Communication

    /// Get a challenge nonce from the server for attestation
    private func fetchAttestationChallenge() async throws -> Data {
        struct ChallengeResponse: Decodable {
            let challenge: String
        }

        let response: ChallengeResponse = try await supabase.functions
            .invoke("verify-attestation", options: .init(
                method: .get
            ))

        guard let data = Data(base64Encoded: response.challenge) else {
            throw AppAttestError.invalidChallenge
        }
        return data
    }

    /// Send attestation to server for verification and storage
    private func verifyAttestationOnServer(
        keyId: String,
        attestation: Data,
        challenge: Data
    ) async throws {
        struct AttestationPayload: Encodable {
            let keyId: String
            let attestation: String  // base64
            let challenge: String    // base64
        }

        let payload = AttestationPayload(
            keyId: keyId,
            attestation: attestation.base64EncodedString(),
            challenge: challenge.base64EncodedString()
        )

        struct VerifyResponse: Decodable {
            let verified: Bool
            let error: String?
        }

        let response: VerifyResponse = try await supabase.functions
            .invoke("verify-attestation", options: .init(
                body: payload
            ))

        guard response.verified else {
            throw AppAttestError.verificationFailed(response.error ?? "Unknown error")
        }
    }

    /// Generate assertion header value for an API request
    func assertionHeader(for requestBody: Data) async -> String? {
        guard isAttested else { return nil }

        do {
            let assertion = try await generateAssertion(for: requestBody)
            return assertion.base64EncodedString()
        } catch {
            #if DEBUG
            print("[AppAttest] Assertion generation failed: \(error)")
            #endif
            return nil
        }
    }
}

// MARK: - Errors

enum AppAttestError: Error, LocalizedError {
    case notSupported
    case noKeyGenerated
    case invalidChallenge
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "App Attest is not available on this device"
        case .noKeyGenerated:
            return "No attestation key has been generated"
        case .invalidChallenge:
            return "Invalid server challenge"
        case .verificationFailed(let reason):
            return "Attestation verification failed: \(reason)"
        }
    }
}
