//
//  RehearApp.swift
//  Rehear
//
//  Created by 倪晨一 on 2026/4/1.
//

import SwiftUI

@main
struct loopRecordingApp: App {
    @StateObject private var language = LanguageManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(language)
                .environment(\.locale, language.locale)
        }
    }
}
