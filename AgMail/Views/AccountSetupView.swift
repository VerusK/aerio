import SwiftUI

struct AccountSetupView: View {
    @ObservedObject var accountManager: AccountManager
    let oauthManager: OAuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            header
            Divider()
            content
        }
        .frame(width: 360, height: 240)
    }

    private var header: some View {
        HStack {
            Text("Add Account")
                .font(.headline)
            Spacer()
            Button("Cancel") {
                dismiss()
            }
        }
        .padding()
    }

    private var content: some View {
        VStack(spacing: 16) {
            Spacer()

            if isAuthenticating {
                ProgressView("Signing in...")
            } else {
                Button(action: signIn) {
                    HStack {
                        Image(systemName: "envelope.fill")
                        Text("Sign in with Google")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(.horizontal)
    }

    private func signIn() {
        isAuthenticating = true
        errorMessage = nil

        Task {
            do {
                let (tokens, accountId) = try await oauthManager.authorize()
                let email = tokens.email

                if accountManager.accounts.contains(where: { $0.email == email }) {
                    errorMessage = "Account \(email) is already added."
                    isAuthenticating = false
                    return
                }

                let color = AccountColor.nextUniqueColor(existingAccounts: accountManager.accounts)
                let account = Account(
                    id: accountId,
                    email: email,
                    displayName: email.components(separatedBy: "@").first ?? email,
                    color: color
                )
                accountManager.addAccount(account)
                isAuthenticating = false
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isAuthenticating = false
            }
        }
    }
}
