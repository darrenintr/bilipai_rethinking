import SwiftUI

struct LoginSheet: View {
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var repository: PaladalaRepository
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: LoginViewModel

    init() {
        // The live `authStore` arrives via `@EnvironmentObject` from the
        // parent; we hand the model a temporary `AuthStore` here and
        // re-bind in `onAppear` so login completions propagate to the
        // environment-provided singleton.
        let placeholder = AuthStore()
        _model = StateObject(wrappedValue: LoginViewModel(authStore: placeholder))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                explanation
                qrCard
                Spacer(minLength: 0)
                footer
            }
            .padding(20)
            .background(PaladalaTheme.canvas)
            .navigationTitle("登录 Bilibili")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        Haptics.tap()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            model.setAuthStore(authStore)
            model.start()
        }
        .onDisappear {
            model.cancel()
        }
        .onChange(of: authStore.activeAccount?.mid) { _, _ in
            if authStore.isLoggedIn {
                // Successful login → unlatch the 401 interceptor so
                // the *next* session-expiry (e.g. SESSDATA rotation
                // in 30 days) can re-pop the sheet. Without this,
                // the latch would stay set forever after the very
                // first 401 burst and subsequent expired sessions
                // would silently fail instead of prompting re-auth.
                repository.apiClient.resetAuthFailureLatch()
                Haptics.success()
                dismiss()
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("扫码登录 Paladala")
                .font(PaladalaTheme.FontRole.displayMedium)
                .foregroundStyle(PaladalaTheme.ink)
                .textCase(.uppercase)
            Text("打开手机 Bilibili App，扫一扫下方二维码即可登录。\n登录后可查看评论、关注动态与个性化首页。")
                .font(PaladalaTheme.FontRole.bodySmall)
                .foregroundStyle(PaladalaTheme.mutedInk)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var qrCard: some View {
        ZStack {
            Rectangle()
                .fill(PaladalaTheme.paper)
                .frame(width: 240, height: 240)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
                .background {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .offset(
                            x: PaladalaTheme.hardShadowOffset,
                            y: PaladalaTheme.hardShadowOffset
                        )
                }
            switch model.state {
            case .generating:
                ProgressView()
            case .waiting(let image, _), .scanned(let image, _):
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            case .expired:
                VStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("二维码已过期")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .error(let message):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(PaladalaTheme.biliPink)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            case .success(let account):
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(PaladalaTheme.biliPink)
                    Text(account.name)
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Text(model.statusText)
                .font(PaladalaTheme.FontRole.bodySmall)
                .foregroundStyle(PaladalaTheme.mutedInk)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    model.regenerate()
                } label: {
                    Label("刷新二维码", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PaladalaGlassButtonStyle(materialDesign: .liquidGlass))
            }
        }
    }
}
