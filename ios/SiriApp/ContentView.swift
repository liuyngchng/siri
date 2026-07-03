//
//  ContentView.swift
//  SiriApp
//
//  Root navigation: ModelSetup → Settings → MainScreen.
//  Ported from Android: MainActivity.kt navigation logic
//

import SwiftUI

struct ContentView: View {
    @StateObject private var contentVM = ContentViewModel()
    @StateObject private var configVM = ConfigViewModel()
    @StateObject private var mainVM = MainViewModel()

    var body: some View {
        Group {
            if !contentVM.modelsReady {
                ModelSetupScreen(onReady: {
                    contentVM.onModelsReady()
                })
            } else if !contentVM.hasConfig {
                SettingsScreen(
                    viewModel: configVM,
                    onBack: {
                        contentVM.onConfigSaved()
                    }
                )
            } else if contentVM.showSettings {
                SettingsScreen(
                    viewModel: configVM,
                    onBack: {
                        contentVM.showSettings = false
                        contentVM.refreshState()
                        _ = mainVM.checkConfig()
                    }
                )
            } else {
                MainScreen(
                    viewModel: mainVM,
                    onNavigateToSettings: {
                        contentVM.showSettings = true
                    }
                )
            }
        }
        .onAppear {
            contentVM.checkInitialState()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
