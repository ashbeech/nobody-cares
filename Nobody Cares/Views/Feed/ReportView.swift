//
//  ReportView.swift
//  Nobody Cares
//
//  Report flow — retro radio-button modal.
//  Per spec Section 9.3:
//  - Flag icon opens this modal
//  - Options: inappropriate, illegal, other
//  - Submit writes to `reports` table
//

import SwiftUI

struct ReportView: View {
    let contentId: UUID
    let onDismiss: () -> Void

    @State private var selectedReason: ReportReason?
    @State private var detail: String = ""
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var error: String?

    var body: some View {
        RetroWindow(title: "REPORT CONTENT", icon: .flag, showCloseBox: true, onClose: onDismiss) {
            VStack(alignment: .leading, spacing: 16) {
                if submitted {
                    submittedView
                } else {
                    formView
                }
            }
            .padding(NCMetrics.dialogPadding)
        }
    }

    // MARK: - Form

    private var formView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SELECT REASON:")
                .font(NCFont.display(13))
                .foregroundColor(NCColor.ink)
                .tracking(0.5)

            // Radio buttons
            ForEach(ReportReason.allCases, id: \.self) { reason in
                radioButton(reason: reason)
            }

            // Detail field (for "other")
            if selectedReason == .other {
                TextField("DESCRIBE THE ISSUE", text: $detail)
                    .font(NCFont.dialogBody)
                    .foregroundColor(NCColor.ink)
                    .padding(8)
                    .retroBorder()
                    .textInputAutocapitalization(.characters)
            }

            if let error {
                Text(error)
                    .font(NCFont.caption)
                    .foregroundColor(NCColor.error)
            }

            HStack {
                Spacer()
                RetroButton(title: "CANCEL", variant: .secondary) {
                    onDismiss()
                }
                RetroButton(
                    title: isSubmitting ? "SUBMITTING..." : "SUBMIT REPORT",
                    variant: .primary,
                    isEnabled: selectedReason != nil && !isSubmitting
                ) {
                    submitReport()
                }
            }
        }
    }

    // MARK: - Submitted

    private var submittedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("REPORT FILED")
                .font(NCFont.display(14))
                .foregroundColor(NCColor.ink)

            Text("Your report has been logged. It will be reviewed by absolutely nobody in a timely manner. Thank you for your contribution to order.")
                .font(NCFont.dialogBody)
                .foregroundColor(NCColor.ink)
                .lineSpacing(4)

            HStack {
                Spacer()
                RetroButton(title: "DISMISS", variant: .primary) {
                    onDismiss()
                }
            }
        }
    }

    // MARK: - Radio Button

    private func radioButton(reason: ReportReason) -> some View {
        Button {
            selectedReason = reason
        } label: {
            HStack(spacing: 10) {
                // Radio indicator
                ZStack {
                    Rectangle()
                        .stroke(NCColor.ink, lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                        .background(NCColor.background)

                    if selectedReason == reason {
                        Rectangle()
                            .fill(NCColor.ink)
                            .frame(width: 8, height: 8)
                    }
                }

                Text(reason.displayName)
                    .font(NCFont.body(13))
                    .foregroundColor(NCColor.ink)
                    .tracking(0.3)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Submit

    private func submitReport() {
        guard let reason = selectedReason else { return }
        isSubmitting = true

        Task {
            do {
                let params = ReportParams(
                    contentId: contentId.uuidString,
                    reason: reason.rawValue,
                    detail: detail.isEmpty ? nil : detail
                )

                try await supabase
                    .from("reports")
                    .insert(params)
                    .execute()

                AnalyticsService.shared.track(.contentReported, metadata: [
                    "content_id": contentId.uuidString,
                    "reason": reason.rawValue,
                ])

                await MainActor.run {
                    submitted = true
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    self.error = "REPORT FAILED. Even your complaints are rejected."
                    isSubmitting = false
                }
            }
        }
    }
}

// MARK: - Report Reason

enum ReportReason: String, CaseIterable {
    case inappropriate
    case illegal
    case other

    var displayName: String {
        switch self {
        case .inappropriate: return "INAPPROPRIATE CONTENT"
        case .illegal: return "ILLEGAL CONTENT"
        case .other: return "OTHER"
        }
    }
}

// MARK: - Report Params

private struct ReportParams: Encodable {
    let contentId: String
    let reason: String
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case contentId = "content_id"
        case reason
        case detail
    }
}
