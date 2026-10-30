import SwiftUI
#if os(iOS)
import AVFAudio
import Speech
#endif

/// Speaking a message into the composer (the mic button). On the Mac it starts the system's
/// dictation in the focused composer (Edit → Start Dictation, no permission needed). On iPhone
/// and iPad it listens with the Speech framework and writes what it hears into the composer as
/// it comes; that needs `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`
/// in the app's Info.plist; without them the button stays hidden (the keyboard has its own
/// dictation).
@Observable
final class AssistantDictation {
    /// Listening right now (iOS).
    private(set) var isListening = false

    static var isAvailable: Bool {
        #if os(macOS)
        true
        #else
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
            && Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
        #endif
    }

    /// The text to start from and what was heard so far, joined.
    static func joined(_ base: String, _ heard: String) -> String {
        if base.isEmpty || heard.isEmpty { return base + heard }
        return base.last?.isWhitespace == true ? base + heard : base + " " + heard
    }

    #if os(macOS)
    /// Starts the system's dictation in the composer (it must have the focus).
    func start() {
        Task {
            // The composer takes the focus first.
            try? await Task.sleep(for: .milliseconds(80))
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }
    #else
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    /// Listens and calls `update` with `base` plus what it heard so far, until `stop()` (or a
    /// pause the recognizer takes as the end).
    func start(base: String, update: @escaping (String) -> Void) async {
        guard !isListening else { return }
        guard await Self.authorize() else {
            ErrorBanner.shared.show(String(localized: "Ohana may not use the microphone or speech recognition. You can allow it in the Settings app."))
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Self.locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            ErrorBanner.shared.show(String(localized: "Dictation isn’t available right now."))
            return
        }
        recognizer.queue = .main
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let engine = AVAudioEngine()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try Self.listen(engine, into: request)
        } catch {
            ErrorBanner.shared.show(error)
            return
        }
        self.engine = engine
        self.request = request
        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result { update(Self.joined(base, result.bestTranscription.formattedString)) }
            if error != nil || result?.isFinal == true { self?.stop() }
        }
    }

    /// Stops listening; what was heard stays in the composer.
    func stop() {
        guard isListening else { return }
        isListening = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        engine = nil
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The app's language for the recognizer.
    private static var locale: Locale {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        if Locale.current.language.languageCode?.identifier == lang { return Locale.current }
        return Locale(identifier: lang == "de" ? "de-DE" : "en-US")
    }

    /// Asks for speech recognition and the microphone (once; the system remembers).
    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Feeds the microphone into the request (the tap runs on the audio thread).
    nonisolated private static func listen(_ engine: AVAudioEngine, into request: SFSpeechAudioBufferRecognitionRequest) throws {
        nonisolated(unsafe) let request = request
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }
    #endif
}
