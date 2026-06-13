import SwiftUI

struct LiveRoomsView: View {
    let repository: BiliPaiRepository

    @StateObject private var model = LiveViewModel()
    private let columns = [GridItem(.adaptive(minimum: 172), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let error = model.errorMessage {
                    ErrorBanner(message: error)
                }
                if model.isLoading && model.rooms.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if model.rooms.isEmpty {
                    ContentUnavailableView(
                        model.errorMessage == nil ? "No live rooms found" : "Live rooms unavailable",
                        systemImage: "play.tv",
                        description: Text(model.errorMessage == nil ? "Pull to refresh the public live list." : "Bilibili did not return a public live-room list for this request.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .background(BiliPaiTheme.cardBackground, in: RoundedRectangle(cornerRadius: BiliPaiTheme.cardRadius))
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.rooms) { room in
                            LiveRoomCard(room: room)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(BiliPaiTheme.pageBackground)
        .navigationTitle("Live")
        .task {
            await model.load(repository: repository)
        }
        .refreshable {
            await model.load(repository: repository)
        }
    }
}
