//
//  RemoteBadgeView.swift
//  CodeLight
//
//  A small badge indicating that a session is running on a remote server.
//  Designed to be overlaid on session list items without modifying existing views.
//
//  This is a standalone file — no existing views are modified.
//

import SwiftUI

/// Small badge showing remote session host info.
struct RemoteBadgeView: View {
    let host: String
    let muxType: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "network")
                .font(.system(size: 9))
            Text(host)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
            if !muxType.isEmpty && muxType != "unknown" {
                Text("·")
                    .font(.system(size: 9))
                Text(muxType)
                    .font(.system(size: 9))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
    }
}

#Preview {
    VStack(spacing: 12) {
        RemoteBadgeView(host: "dgx-127", muxType: "zellij")
        RemoteBadgeView(host: "deploy-01", muxType: "tmux")
        RemoteBadgeView(host: "myserver", muxType: "")
    }
    .padding()
}
