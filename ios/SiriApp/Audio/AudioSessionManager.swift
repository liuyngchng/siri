//
//  AudioSessionManager.swift
//  SiriApp
//
//  Configures AVAudioSession for playback & recording.
//  Ported from Android: VoiceService.kt (foreground service + audio routing)
//

import Foundation
import AVFoundation
import os.log

enum AudioSessionManager {

    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true)
            os_log(.info, "AudioSession configured: playAndRecord")
        } catch {
            os_log(.error, "Failed to configure audio session: %{public}@",
                   error.localizedDescription)
        }
    }

    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            os_log(.error, "Failed to deactivate audio session: %{public}@",
                   error.localizedDescription)
        }
    }
}
