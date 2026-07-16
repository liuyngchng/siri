//
//  SiriAppApp.swift
//  SiriApp
//
//  @main entry point for the SwiftUI app.
//  Ported from Android: MainActivity.kt / SiriApp.kt
//

import SwiftUI

@main
struct SiriAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
