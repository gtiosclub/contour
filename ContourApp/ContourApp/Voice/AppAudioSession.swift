//
//  AppAudioSession.swift
//  ContourApp — Officers (integration)
//
//  The one audio session setup the app's own speech and microphone share, so
//  nothing switches it between a sentence and listening.
//

import AVFoundation

nonisolated enum AppAudioSession {
    /// Play and record, so the microphone can open without a switch. On the
    /// speaker rather than the earpiece, heard in Silent Mode, mixed with VoiceOver,
    /// and on AirPods when they're connected, while the phone's microphone listens.
    /// Not AirPlay: its delay of a second or more would play "Say next to move on"
    /// into the open microphone.
    static let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP]

    /// ContourFeedback's guidance cues set `.playback` when they start, so this sets
    /// it back only if something changed it.
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord || session.mode != .default || session.categoryOptions != options {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
        }
        try session.setActive(true)
    }
}
