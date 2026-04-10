//
//  VoiceCommandOverlay.swift
//  NexGenSpec
//
//  Floating mic button + transcript display for hands-free voice commands.
//  Pro-only feature. Overlays the inspection view as a ZStack layer.
//

import SwiftUI

struct VoiceCommandOverlay: View {

    @ObservedObject var voiceManager: VoiceCommandManager
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @State private var showPaywall = false
    @State private var showCommandList = false
    @State private var feedbackText: String?
    @State private var feedbackOpacity: Double = 0

    var body: some View {
        VStack {
            Spacer()

            // Transcript / feedback toast
            if let text = feedbackText {
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.75))
                    )
                    .opacity(feedbackOpacity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 8)
            }

            // Live transcript while listening
            if voiceManager.isListening && !voiceManager.transcript.isEmpty {
                Text(voiceManager.transcript)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.blue.opacity(0.7))
                    )
                    .padding(.bottom, 4)
            }

            HStack {
                Spacer()

                // Command list button
                if voiceManager.isListening {
                    Button {
                        showCommandList.toggle()
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(AppColor.accent.opacity(0.8)))
                    }
                    .accessibilityLabel("Voice command list")
                    .transition(.scale.combined(with: .opacity))
                }

                // Main mic button
                Button {
                    micTapped()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                voiceManager.isListening
                                    ? LinearGradient(colors: [.red, .red.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                                    : LinearGradient(colors: [AppColor.brandBlue, AppColor.brandCyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 56, height: 56)
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)

                        if voiceManager.isListening {
                            // Pulsing ring
                            Circle()
                                .stroke(Color.red.opacity(0.4), lineWidth: 3)
                                .frame(width: 66, height: 66)
                                .scaleEffect(voiceManager.isListening ? 1.2 : 1.0)
                                .opacity(voiceManager.isListening ? 0.0 : 1.0)
                                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false), value: voiceManager.isListening)
                        }

                        Image(systemName: voiceManager.isListening ? "mic.fill" : "mic")
                            .font(.title2.weight(.semibold))
                            .foregroundColor(.white)
                    }
                }
                .accessibilityLabel(voiceManager.micAccessibilityLabel)
                .accessibilityHint(voiceManager.isListening ? "Tap to stop listening" : "Tap to start voice commands")
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)
        }
        .animation(.spring(response: 0.3), value: voiceManager.isListening)
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(subscriptions)
        }
        .sheet(isPresented: $showCommandList) {
            VoiceCommandListSheet(voiceManager: voiceManager)
        }
        .onChange(of: voiceManager.auditLog.count) { _ in
            if let last = voiceManager.auditLog.last {
                showFeedback(last.result)
            }
        }
    }

    private func micTapped() {
        if voiceManager.isListening {
            voiceManager.stopListening()
            return
        }
        guard subscriptions.isPro else {
            showPaywall = true
            return
        }
        voiceManager.requestAuthorization { authorized in
            if authorized {
                voiceManager.startListening()
            }
        }
    }

    private func showFeedback(_ text: String) {
        withAnimation(.easeIn(duration: 0.2)) {
            feedbackText = text
            feedbackOpacity = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.5)) {
                feedbackOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                feedbackText = nil
            }
        }
    }
}

// MARK: - Command list sheet

private struct VoiceCommandListSheet: View {
    @ObservedObject var voiceManager: VoiceCommandManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Say any of these commands:") {
                    commandRow("\"Add note ...\"", "Adds a note to the current item")
                    commandRow("\"Next room\"", "Navigate to the next section")
                    commandRow("\"Previous room\"", "Navigate to the previous section")
                    commandRow("\"Capture photo\"", "Opens the camera")
                    commandRow("\"Defect: ...\"", "Log a defect with description")
                    commandRow("\"Go to summary\"", "Navigate to summary view")
                    commandRow("\"Go to finalize\"", "Navigate to finalize view")
                }
                if !voiceManager.auditLog.isEmpty {
                    Section("Recent Commands") {
                        ForEach(voiceManager.auditLog.suffix(10).reversed()) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.command ?? "Unrecognized")
                                    .font(.subheadline.weight(.medium))
                                Text(entry.result)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Voice Commands")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func commandRow(_ trigger: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(trigger)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppColor.accent)
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}
