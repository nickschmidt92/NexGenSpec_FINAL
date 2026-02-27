import Foundation
import Speech
import AVFoundation
import SwiftUI
import Combine

/// A manager class to handle voice commands using Speech framework.
/// Provides SwiftUI bindings for listening state, transcripts, errors, and command parsing.
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
    - "Add note ..." (e.g., "Add note buy milk")
    - "Next room"
    - "Capture photo"
    - "Defect: ..." (e.g., "Defect: broken window")
    - "Start recording"
    - "Stop recording"
    """
    
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
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
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
            recognitionRequest?.endAudio()
            recognitionTask?.cancel()
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
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        // Accessibility announcement
        UIAccessibility.post(notification: .announcement, argument: "Voice command listening started")
    }
    
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
        let lowerTranscript = transcript.lowercased()
        var command: String?
        var result: String?
        
        if lowerTranscript.hasPrefix("add note") {
            command = "Add note"
            let noteContent = transcript.dropFirst("add note".count).trimmingCharacters(in: .whitespacesAndNewlines)
            result = noteContent.isEmpty ? "Add note command recognized but note content is empty" : "Note added: \(noteContent)"
        } else if lowerTranscript == "next room" {
            command = "Next room"
            result = "Navigating to next room"
        } else if lowerTranscript == "capture photo" {
            command = "Capture photo"
            result = "Photo capture command recognized"
        } else if lowerTranscript.hasPrefix("defect:") {
            command = "Defect"
            let defectDescription = transcript.dropFirst("defect:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            result = defectDescription.isEmpty ? "Defect command recognized but description is empty" : "Defect noted: \(defectDescription)"
        } else if lowerTranscript == "start recording" {
            command = "Start recording"
            result = "Start recording command recognized"
        } else if lowerTranscript == "stop recording" {
            command = "Stop recording"
            result = "Stop recording command recognized"
        } else {
            command = nil
            result = "Unrecognized command"
        }
        
        if let cmd = command {
            UIAccessibility.post(notification: .announcement, argument: "\(cmd) command received")
        } else {
            UIAccessibility.post(notification: .announcement, argument: "Unrecognized voice command")
        }
        
        return (command, result ?? "")
    }
    
    // MARK: - Audit Logging
    
    private func logAudit(transcript: String, command: String?, result: String) {
        let entry = AuditLogEntry(timestamp: Date(), transcript: transcript, command: command, result: result)
        auditLog.append(entry)
    }
}
