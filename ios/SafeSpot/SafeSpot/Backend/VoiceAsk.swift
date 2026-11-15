//  VoiceAsk.swift
//  Captures a spoken question ("Where do I go next?") with on-device speech
//  recognition and hands back the transcript. The answer itself comes from the
//  backend /voice agent (route-state only) and is spoken via AVSpeech in the view.
//
//  Press to start listening; press again (or auto-stop after a pause) to finish.
//  Permissions: NSMicrophoneUsageDescription + NSSpeechRecognitionUsageDescription.

import Foundation
import Speech
import AVFoundation
import Observation

@MainActor
@Observable
final class VoiceAsk {
    private(set) var listening = false
    private(set) var heard = ""
    private(set) var error: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?

    /// `onResult` fires once with the final transcript when listening ends.
    var onResult: ((String) -> Void)?

    func toggle() { listening ? stop() : start() }

    func start() {
        guard !listening else { return }
        error = nil; heard = ""
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                guard auth == .authorized else { self.error = "Speech access denied"; return }
                self.beginListening()
            }
        }
    }

    private func beginListening() {
        guard let recognizer, recognizer.isAvailable else { error = "Speech not available"; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                self?.request?.append(buf)
            }
            engine.prepare()
            try engine.start()
            listening = true

            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.heard = result.bestTranscription.formattedString
                        self.resetSilenceTimer()           // stop ~1.2 s after speech pauses
                        if result.isFinal { self.finish() }
                    }
                    if err != nil { self.finish() }
                }
            }
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    /// End listening and deliver the transcript (if any).
    func finish() {
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        if !text.isEmpty { onResult?(text) }
    }

    func stop() {
        silenceTimer?.invalidate(); silenceTimer = nil
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
