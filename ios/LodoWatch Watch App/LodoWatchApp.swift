//
//  LodoWatchApp.swift
//  LodoWatch Watch App
//
//  Created by Lu Zhan on 15/7/2026.
//

import SwiftUI
import SwiftData

@main
struct LodoWatch_Watch_AppApp: App {
    var body: some Scene {
        WindowGroup {
            WatchTodoListView()
                .modelContainer(WatchDatabase.container)
        }
    }
}
