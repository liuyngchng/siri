//
//  AppDelegate.swift
//  SiriApp
//
//  App delegate for audio session configuration and app lifecycle.
//  Ported from Android: SiriApp.kt (Application class)
//

import UIKit
import AVFoundation
import os.log

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        os_log(.info, "AppDelegate: didFinishLaunching")
        configureAudioSession()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        os_log(.info, "AppDelegate: willResignActive")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        os_log(.info, "AppDelegate: didBecomeActive")
        configureAudioSession()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        os_log(.info, "AppDelegate: willTerminate")
        AudioSessionManager.deactivate()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true)
            os_log(.info, "AppDelegate: audio session configured")
        } catch {
            os_log(.error, "AppDelegate: audio session config failed: %{public}@",
                   error.localizedDescription)
        }
    }
}
