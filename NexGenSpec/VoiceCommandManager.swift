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

                    // When final result, parse commands
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
        let commandResult = parseCommand(transcript: transcript)
        logAudit(transcript: transcript, command: commandResult.command, result: commandResult.result)
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
    func parseCommand(transcript: String) -> (command: String?, result: String) {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var command: String?
        var result: String?
        var action: CommandAction?

        if lower.hasPrefix("add note") {
            command = "Add note"
            let content = transcript.dropFirst("add note".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty {
                result = "Add note: no content provided"
            } else {
                result = "Note added: \(content)"
                action = .addNote(content)
            }
        } else if lower == "next room" || lower == "next section" {
            command = "Next section"
            result = "Navigating to next section"
            action = .nextSection
        } else if lower == "previous room" || lower == "previous section" {
            command = "Previous section"
            result = "Navigating to previous section"
            action = .previousSection
        } else if lower == "capture photo" || lower == "take photo" {
            command = "Capture photo"
            result = "Photo capture triggered"
            action = .capturePhoto
        } else if lower.hasPrefix("defect") {
            command = "Defect"
            let stripped = lower.hasPrefix("defect:") ? String(transcript.dropFirst("defect:".count)) : String(transcript.dropFirst("defect".count))
            let desc = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if desc.isEmpty {
                result = "Defect: no description provided"
            } else {
                result = "Defect noted: \(desc)"
                action = .defect(desc)
            }
        } else if lower == "go to summary" || lower == "summary" {
            command = "Go to summary"
            result = "Navigating to summary"
            action = .goToSummary
        } else if lower == "go to finalize" || lower == "finalize" {
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

        // Dispatch the action to the host view
        if let action {
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
