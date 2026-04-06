import SwiftUI

/// List of sessions for a given server.
struct SessionListView: View {
    @EnvironmentObject var appState: AppState
    let server: ServerConfig
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            // Connection status banner
            ConnectionStatusBar()

            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(String(localized: "loading_sessions"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appState.sessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
        }
        .navigationTitle(server.name)
        .navigationDestination(for: String.self) { sessionId in
            ChatView(sessionId: sessionId)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    // Refresh
                    Button {
                        Task { await refreshSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    // Settings
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .task {
            if let socket = appState.socket {
                do {
                    appState.sessions = try await socket.fetchSessions()
                } catch {
                    print("[SessionList] Fetch error: \(error)")
                }
            }
            isLoading = false
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.5))

            VStack(spacing: 8) {
                Text(String(localized: "no_sessions_yet"))
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(String(localized: "no_sessions_instruction"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "1.circle.fill")
                        .foregroundStyle(.blue)
                    Text(String(localized: "step_install_codeisland"))
                        .font(.caption)
                }

                HStack(spacing: 8) {
                    Image(systemName: "2.circle.fill")
                        .foregroundStyle(.blue)
                    Text(String(localized: "step_start_session"))
                        .font(.caption)
                }

                HStack(spacing: 8) {
                    Image(systemName: "3.circle.fill")
                        .foregroundStyle(.blue)
                    Text(String(localized: "step_sessions_appear"))
                        .font(.caption)
                }
            }
            .padding()
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))

            Button {
                Task { await refreshSessions() }
            } label: {
                Label(String(localized: "refresh"), systemImage: "arrow.clockwise")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding()
    }

    // MARK: - Session List

    private var sessionList: some View {
        List {
            // Active sessions
            let active = appState.sessions.filter(\.active)
            if !active.isEmpty {
                Section {
                    ForEach(active) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.brand)
                            .frame(width: 6, height: 6)
                        Text(String(localized: "active"))
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(active.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.brandSoft, in: Capsule())
                            .foregroundStyle(Theme.brand)
                    }
                }
            }

            // Inactive sessions
            let inactive = appState.sessions.filter { !$0.active }
            if !inactive.isEmpty {
                Section(String(localized: "recent")) {
                    ForEach(inactive) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bgPrimary)
        .refreshable {
            await refreshSessions()
        }
    }

    // MARK: - Helpers

    private func refreshSessions() async {
        if let socket = appState.socket {
            appState.sessions = (try? await socket.fetchSessions()) ?? []
        }
    }
}

/// Shorten a path by replacing home directory with ~
private func shortenPath(_ path: String) -> String {
    var p = path
    if let home = ProcessInfo.processInfo.environment["HOME"], p.hasPrefix(home) {
        p = "~" + p.dropFirst(home.count)
    }
    return p
}

/// A single session row.
private struct SessionRow: View {
    @EnvironmentObject var appState: AppState
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator: brand-lime dot for active, dim for idle.
            ZStack {
                if session.active {
                    Circle()
                        .fill(Theme.brand.opacity(0.25))
                        .frame(width: 18, height: 18)
                }
                Circle()
                    .fill(session.active ? Theme.brand : Theme.textTertiary)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.metadata?.displayProjectName ?? session.tag)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                if let title = session.metadata?.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                if let path = session.metadata?.path {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 8))
                        Text(shortenPath(path))
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let model = session.metadata?.model {
                    Text(model.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.brandSoft, in: Capsule())
                        .overlay(Capsule().stroke(Theme.borderActive, lineWidth: 0.5))
                        .foregroundStyle(Theme.brand)
                }

                if let lastTime = appState.lastMessageTimeBySession[session.id] {
                    Text(lastTime, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Theme.bgPrimary)
        .listRowSeparatorTint(Theme.divider)
    }
}
