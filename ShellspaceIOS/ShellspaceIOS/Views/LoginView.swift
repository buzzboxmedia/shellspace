import SwiftUI

struct LoginView: View {
    @Environment(AppViewModel.self) private var viewModel

    @State private var email = ""
    @State private var password = ""
    @State private var isSignup = false
    @State private var isLoading = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                // Logo / Title
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundStyle(.primary)

                    Text("Shellspace")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text(isSignup ? "Create your account" : "Sign in to connect to your Mac")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 40)

                // Form fields
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Email")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        TextField("you@example.com", text: $email)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .padding(14)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Password")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        SecureField("Password", text: $password)
                            .textContentType(isSignup ? .newPassword : .password)
                            .padding(14)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 24)

                // Error
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                }

                // Submit button
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isSignup ? "Create Account" : "Sign In")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(isFormValid ? Color.accentColor : Color.gray.opacity(0.3))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!isFormValid || isLoading)
                .padding(.horizontal, 24)
                .padding(.top, 24)

                // Toggle signup / login
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSignup.toggle()
                        errorMessage = ""
                    }
                } label: {
                    Text(isSignup ? "Already have an account? Sign In" : "Don't have an account? Create one")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.top, 16)

                Spacer()
                Spacer()
            }
            .navigationBarHidden(true)
        }
    }

    private var isFormValid: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        password.count >= 6
    }

    private func submit() async {
        errorMessage = ""
        isLoading = true
        defer { isLoading = false }

        let trimmedEmail = email.trimmingCharacters(in: .whitespaces).lowercased()

        do {
            if isSignup {
                try await viewModel.relayAuth.signup(email: trimmedEmail, password: password)
            } else {
                try await viewModel.relayAuth.login(email: trimmedEmail, password: password)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
