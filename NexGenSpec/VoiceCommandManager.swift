import Foundation
import Speech
import AVFoundation
import SwiftUI
import Combine

/// A manager class to handle voice commands using Speech framework.
/// Provides SwiftUI bindings for listening state, transcripts, errors, and command parsing.
@MainActor
final class VoiceCommandManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties for SwiftUI Bindings
    
    /// Whether the manager is currently listening.
    @Published private(set) var isListening: Bool = false
    
    /// The latest transcribed text from speech recognition.
    @Published private(set) var transcript: String = ""
    
    /// The latest error message, if any.
    @Published private(set) var errorMessage: String?
    
    /// Accessibility label for microphone state.
    @Published private(set) var micAccessibilityLabel: String = "Microphone is off"
    
    /// Cheat sheet of supported commands.
    let supportedCommands = """
    Supported voice commands:
    - "Add note ..." (e.g., "Add note cracked foundation")
    - "Next room" / "Next section"
    - "Previous room" / "Previous section"
    - "Capture photo"
    - "Defect: ..." (e.g., "Defect: broken window")
    - "Go to summary"
    - "Go to finalize"
    """

    /// Recognized command actions the host view should handle.
    enum CommandAction {
        case addNote(String)
        case nextSection
        case previousSection
        case capturePhoto
        case defect(String)
        case goToSummary
        case goToFinalize
    }

    /// Callback for recognized commands. Set by the hosting view.
    var onCommand: ((CommandAction) -> Void)?
    
    // MARK: - Private Properties
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    private var cancellables = Set<AnyCancellable>()

    /// Last transcript that produced a command. Used to debounce partial-result
    /// matching so we don't re-fire the same command as the recognizer keeps
    /// emitting partials with the same text.
    private var lastFiredTranscript: String = ""
    
    // Command log entry struct
    struct AuditLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let transcript: String
        let command: String?
        let result: String
    }
    
    /// List of all command attempts and results logged.
    @Published private(set) var auditLog: [AuditLogEntry] = []
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        configureAccessibility()
    }
    
    private func configureAccessibility() {
        $isListening
            .sink { [weak self] listening in
                self?.micAccessibilityLabel = listening ? "Microphone is on and listening" : "Microphone is off"
                UIAccessibility.post(notification: .layoutChanged, argument: self?.micAccessibilityLabel)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Authorization
    
    /// Requests authorization for speech recognition and audio session.
    /// Calls completion with success status.
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    self?.requestAudioSessionAuthorization(completion: completion)
                case .denied, .restricted, .notDetermined:
                    self?.errorMessage = "Speech recognition authorization denied or restricted."
                    self?.logAudit(transcript: "", command: nil, result: "Authorization denied")
                    completion(false)
                @unknown default:
                    self?.errorMessage = "Unknown speech recognition authorization status."
                    self?.logAudit(transcript: "", command: nil, result: "Authorization unknown error")
                    completion(false)
                }
            }
        }
    }
    
    private func requestAudioSessionAuthorization(completion: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    completion(true)
                } else {
                    self?.errorMessage = "Microphone access denied."
                    self?.logAudit(transcript: "", command: nil, result: "Microphone permission denied")
                    completion(false)
                }
            }
        }

        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                finish(true)
            case .denied:
                finish(false)
            case .undetermined:
                AVAudioApplication.requestRecordPermission(completionHandler: { granted in
                    finish(granted)
                })
            @unknown default:
                finish(false)
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                finish(granted)
            }
        }
    }
    
    // MARK: - Listening Control
    
    /// Starts listening and recognizing voice commands.
    func startListening() {
        errorMessage = nil
        guard !audioEngine.isRunning else { return }
        
        do {
            try startAudioEngine()
            isListening = true
            micAccessibilityLabel = "Microphone is on and listening"
        } catch {
            errorMessage = "Audio engine start failed: \(error.localizedDescription)"
            isListening = false
            micAccessibilityLabel = "Microphone is off"
            logAudit(transcript: "", command: nil, result: "Audio engine start failed: \(error.localizedDescription)")
        }
    }
    
    /// Stops listening and recognition.
    func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            recognitionRequest?.endAudio()
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            transcript = ""
            lastFiredTranscript = ""
            isListening = false
            micAccessibilityLabel = "Microphone is off"
        }
    }
    
    // MARK: - Private Audio Engine Setup
    
    private func startAudioEngine() throws {
        // Cancel previous task if running
        recognitionTask?.cancel()
        recognitionTask = nil
        
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "VoiceCommandManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            Task { @MainActor in
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString

                    // Parse on every partial — `isFinal` only fires after several
                    // seconds of silence, which is too slow for interactive
                    // commands. We debounce by remembering the last transcript
                    // that matched a command so we don't re-fire as the
                    // recognizer keeps emitting partials with the same text.
                    self.tryHandlePartialTranscript(self.transcript)

                    if result.isFinal {
                        self.handleFinalTranscript(self.transcript)
                    }
                }

                if let error = error {
                    self.errorMessage = "Recognition error: \(error.localizedDescription)"
                    self.stopListening()
                    self.logAudit(transcript: self.transcript, command: nil, result: "Recognition error: \(error.localizedDescription)")
                }
            }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        // Accessibility announcement
        UIAccessibility.post(notification: .announcement, argument: "Voice command listening started")
    }

    // Note: cleanup happens in stopListening(). deinit is not safe for
    // @MainActor classes since it may run off-main. The audioEngine is
    // stopped via stopListening() before the manager is released.
    
    // MARK: - Command Parsing
    
    private func handleFinalTranscript(_ transcript: String) {
        // On isFinal, clear the debounce so the next utterance can re-fire a
        // previously-used command (e.g. "next room" twice in a row).
        lastFiredTranscript = ""
        let commandResult = parseCommand(transcript: transcript)
        logAudit(transcript: transcript, command: commandResult.command, result: commandResult.result)
    }

    /// Called on every partial result. Tries to match a command; if one matches
    /// and hasn't been fired for this utterance yet, fires it and restarts the
    /// recognition session to clear the buffer for the next command.
    private func tryHandlePartialTranscript(_ transcript: String) {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != lastFiredTranscript else { return }

        let commandResult = parseCommand(transcript: transcript, fireAction: false)
        guard commandResult.command != nil else { return }

        // Matched — debounce this transcript, log, fire the action once, then
        // restart recognition so the next spoken command starts fresh.
        lastFiredTranscript = normalized
        logAudit(transcript: transcript, command: commandResult.command, result: commandResult.result)
        _ = parseCommand(transcript: transcript, fireAction: true)
        restartRecognition()
    }

    /// Tears down the current recognition task/request and starts a fresh one
    /// so the recognizer's internal transcript buffer is cleared. The audio
    /// engine keeps running so the user doesn't perceive any gap.
    private func restartRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        transcript = ""
        lastFiredTranscript = ""

        // Re-attach a new recognition request to the already-running audio engine.
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        recognitionRequest = newRequest

        recognitionTask = speechRecognizer?.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self = self else { return }
            Task { @MainActor in
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                    self.tryHandlePartialTranscript(self.transcript)
                    if result.isFinal {
                        self.handleFinalTranscript(self.transcript)
                    }
                }
                if let error = error {
                    // Silent on restart errors — the user can tap mic again.
                    self.logAudit(transcript: self.transcript, command: nil,
                                  result: "Recognition restart error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Parses transcript and returns recognized command and processing result.
    /// Supported commands:
    /// - "Add note ..."
    /// - "Next room"
    /// - "Capture photo"
    /// - "Defect: ..."
    /// - "Start recording"
    /// - "Stop recording"
    ///
    /// - Parameter transcript: The recognized speech text.
    /// - Returns: A tuple with the recognized command string (or nil) and a human-readable result string.
    @discardableResult
    func parseCommand(transcript: String, fireAction: Bool = true) -> (command: String?, result: String) {
        // Strip trailing punctuation Apple's recognizer sometimes adds
        // ("go to summary." / "next room,") so matches still hit.
        let trimmingSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let lower = transcript.lowercased().trimmingCharacters(in: trimmingSet)
        var command: String?
        var result: String?
        var action: CommandAction?

        if lower.hasPrefix("add note") {
            command = "Add note"
            let content = transcript.dropFirst("add note".count).trimmingCharacters(in: trimmingSet)
            if content.isEmpty {
                result = "Add note: no content provided"
            } else {
                result = "Note added: \(content)"
                action = .addNote(content)
            }
        } else if lower == "next room" || lower == "next section"
                    || lower.hasSuffix(" next room") || lower.hasSuffix(" next section") {
            command = "Next section"
            result = "Navigating to next section"
            action = .nextSection
        } else if lower == "previous room" || lower == "previous section"
                    || lower.hasSuffix(" previous room") || lower.hasSuffix(" previous section") {
            command = "Previous section"
            result = "Navigating to previous section"
            action = .previousSection
        } else if lower == "capture photo" || lower == "take photo"
                    || lower.hasSuffix(" capture photo") || lower.hasSuffix(" take photo") {
            command = "Capture photo"
            result = "Photo capture triggered"
            action = .capturePhoto
        } else if lower.hasPrefix("defect") {
            command = "Defect"
            let stripped = lower.hasPrefix("defect:") ? String(transcript.dropFirst("defect:".count)) : String(transcript.dropFirst("defect".count))
            let desc = stripped.trimmingCharacters(in: trimmingSet)
            if desc.isEmpty {
                result = "Defect: no description provided"
            } else {
                result = "Defect noted: \(desc)"
                action = .defect(desc)
            }
        } else if lower == "go to summary" || lower == "summary"
                    || lower.hasSuffix(" go to summary") || lower.hasSuffix(" summary") {
            command = "Go to summary"
            result = "Navigating to summary"
            action = .goToSummary
        } else if lower == "go to finalize" || lower == "finalize"
                    || lower.hasSuffix(" go to finalize") || lower.hasSuffix(" finalize") {
            command = "Go to finalize"
            result = "Navigating to finalize"
            action = .goToFinalize
        } else {
            command = nil
            result = "Unrecognized command"
        }

        if let cmd = command {
            UIAccessibility.post(notification: .announcement, argument: "\(cmd) command received")
        } else {
            UIAccessibility.post(notification: .announcement, argument: "Unrecognized voice command")
        }

        // Dispatch the action to the host view. Partial-result matches pass
        // fireAction=false so the caller can debounce before firing.
        if fireAction, let action {
            onCommand?(action)
        }

        return (command, result ?? "")
    }
    
    // MARK: - Audit Logging
    
    private func logAudit(transcript: String, command: String?, result: String) {
        let entry = AuditLogEntry(timestamp: Date(), transcript: transcript, command: command, result: result)
        auditLog.append(entry)
    }
}
