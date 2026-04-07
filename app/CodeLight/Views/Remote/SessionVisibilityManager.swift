//
//  SessionVisibilityManager.swift
//  CodeLight
//
//  Manages session visibility (hide/show) for remote sessions.
//  State is stored locally in UserDefaults — no backend changes needed.
//
//  This is a standalone file — no existing views or models are modified.
//

import SwiftUI

/// Manages which sessions are hidden by the user (local-only storage).
@MainActor
class SessionVisibilityManager: ObservableObject {
    static let shared = SessionVisibilityManager()

    @AppStorage("hiddenSessionIds") private var hiddenIdsJSON: String = "[]"

    /// Set of session IDs that are currently hidden.
    var hiddenIds: Set<String> {
        get {
            guard let data = hiddenIdsJSON.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(array)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue)),
               let json = String(data: data, encoding: .utf8) {
                hiddenIdsJSON = json
            }
        }
    }

    func isHidden(_ sessionId: String) -> Bool {
        hiddenIds.contains(sessionId)
    }

    func toggle(_ sessionId: String) {
        var ids = hiddenIds
        if ids.contains(sessionId) {
            ids.remove(sessionId)
        } else {
            ids.insert(sessionId)
        }
        hiddenIds = ids
        objectWillChange.send()
    }

    func show(_ sessionId: String) {
        var ids = hiddenIds
        ids.remove(sessionId)
        hiddenIds = ids
        objectWillChange.send()
    }

    func hide(_ sessionId: String) {
        var ids = hiddenIds
        ids.insert(sessionId)
        hiddenIds = ids
        objectWillChange.send()
    }

    var hiddenCount: Int {
        hiddenIds.count
    }

    func showAll() {
        hiddenIds = []
        objectWillChange.send()
    }
}
