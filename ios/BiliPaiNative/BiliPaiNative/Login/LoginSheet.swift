import SwiftUI

struct LoginSheet: View {
    @EnvironmentObject private var authStore: AuthStore
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
                Haptics.success()
                dismiss()
            }
        }
    }

    private var explanation: some View {
        VStack(spacing: 8) {
            Text("扫码登录 Paladala")
                .font(.title3.weight(.bold))
            Text("打开手机 Bilibili App，扫一扫下方二维码即可登录。\n登录后可查看评论、关注动态与个性化首页。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BiliPaiTheme.heroRadius, style: BiliPaiTheme.cornerStyle)
                .fill(BiliPaiTheme.cardBackground)
                .frame(width: 240, height: 240)
                .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 6)
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
                        .foregroundStyle(.orange)
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
                        .foregroundStyle(BiliPaiTheme.biliPink)
                    Text(account.name)
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Text(model.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    model.regenerate()
                } label: {
                    Label("刷新二维码", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
