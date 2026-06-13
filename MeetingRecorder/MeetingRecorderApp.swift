//
//  MeetingRecorderApp.swift
//  MeetingRecorder
//
//  App entry point. Configures a single macOS window with a unified toolbar.
//  The "New Item" command is removed because this app has no document model —
//  there is only one window, one engine, and one recording session at a time.
//
//  Author : Ibrahim Sultan
//  Requires: macOS 15 (Sequoia) · Xcode 16 · Swift 5.10
//

import SwiftUI

/// Root application struct. Owns the single `ContentView` window.
@main
struct MeetingRecorderApp: App {

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Standard title-bar chrome with an integrated toolbar strip.
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // Remove File → New (⌘N) — there is no "new document" concept here.
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
