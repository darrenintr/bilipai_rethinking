import SwiftUI

struct RootView: View {
    let repository: BiliPaiRepository

    @EnvironmentObject private var router: AppRouter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("bilipai.materialDesign") private var materialDesign: MaterialDesign = .material3

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                PadRootView(repository: repository)
            } else {
                PhoneRootView(repository: repository)
            }
        }
        .onAppear {
            router.consumePendingIntentRoute()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                router.consumePendingIntentRoute()
            }
        }
        .onOpenURL { url in
            handle(url)
        }
        .sheet(isPresented: $router.isLoginSheetPresented) {
            LoginSheet()
        }
        .modifier(LiquidGlassTabBarModifier(materialDesign: materialDesign))
    }

    private func handle(_ url: URL) {
        guard url.scheme == "bilipai" else { return }
        switch url.host {
        case "home":
            router.open(.home)
        case "dynamic":
            router.open(.dynamic)
        case "live":
            router.open(.live)
        case "settings":
            router.open(.profile)
        case "search":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "q" })?
                .value ?? ""
            router.openSearch(query)
        case "login":
            router.openLogin()
        default:
            break
        }
    }
}

private struct PhoneRootView: View {
    let repository: BiliPaiRepository
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        NavigationStack(path: $router.path) {
            TabView(selection: $router.selectedTab) {
                HomeView(repository: repository)
                    .tabItem { Label(MainTab.home.title, systemImage: MainTab.home.symbolName) }
                    .tag(MainTab.home)

                DynamicFeedView(repository: repository)
                    .tabItem { Label(MainTab.dynamic.title, systemImage: MainTab.dynamic.symbolName) }
                    .tag(MainTab.dynamic)

                LiveRoomsView(repository: repository)
                    .tabItem { Label(MainTab.live.title, systemImage: MainTab.live.symbolName) }
                    .tag(MainTab.live)

                ProfileSettingsView(repository: repository)
                    .tabItem { Label(MainTab.profile.title, systemImage: MainTab.profile.symbolName) }
                    .tag(MainTab.profile)
            }
            .navigationDestination(for: BiliVideo.self) { video in
                VideoDetailView(video: video, repository: repository)
            }
        }
    }
}

private struct PadRootView: View {
    let repository: BiliPaiRepository
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(MainTab.allCases) { tab in
                    Button {
                        router.open(tab)
                    } label: {
                        Label(tab.title, systemImage: tab.symbolName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(router.selectedTab == tab ? BiliPaiTheme.biliPink.opacity(0.14) : Color.clear)
                }
            }
            .navigationTitle("BiliPai")
        } detail: {
            NavigationStack(path: $router.path) {
                selectedView
                    .navigationDestination(for: BiliVideo.self) { video in
                        VideoDetailView(video: video, repository: repository)
                    }
            }
        }
    }

    @ViewBuilder
    private var selectedView: some View {
        switch router.selectedTab {
        case .home:
            HomeView(repository: repository)
        case .dynamic:
            DynamicFeedView(repository: repository)
        case .live:
            LiveRoomsView(repository: repository)
        case .profile:
            ProfileSettingsView(repository: repository)
        }
    }
}

/// Liquid Glass material for the iOS 18 toolchain. The `.glass` symbol
/// in `.toolbarBackground(.glass, for: .tabBar)` is iOS 26 only and
/// the unsigned-IPA workflow ships with Xcode 16 (iOS 18.5 SDK). For
/// the Liquid Glass preset we use the next-best approximation: a
/// `.ultraThinMaterial` tab bar background with a hairline top edge.
private struct LiquidGlassTabBarModifier: ViewModifier {
    let materialDesign: MaterialDesign

    @ViewBuilder
    func body(content: Content) -> some View {
        switch materialDesign {
        case .material3:
            content
        case .liquidGlass:
            content
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }
}
