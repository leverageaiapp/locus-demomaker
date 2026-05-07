import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// Probes the TCC permissions ScreenStudio needs:
/// 1. **Screen Recording** — required by ScreenCaptureKit.
/// 2. **Accessibility** — required to install a global CGEventTap so we receive mouse
///    events from other apps in addition to our own.
/// 3. **Camera** — required for the fixed presenter bubble.
@MainActor
final class PermissionsManager: ObservableObject {
    @Published var screenRecordingGranted: Bool = false
    @Published var accessibilityGranted: Bool = false
    @Published var microphoneGranted: Bool = false
    @Published var cameraGranted: Bool = false

    func refresh() async {
        screenRecordingGranted = await Self.checkScreenRecording()
        accessibilityGranted = Self.checkAccessibility()
        microphoneGranted = Self.checkMicrophone()
        cameraGranted = Self.checkCamera()
    }

    /// Triggers the system prompt for screen recording the first time it is called.
    /// On subsequent calls (after the user denies), it just returns the current state.
    static func checkScreenRecording() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    static func checkAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    static func checkCamera() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func checkMicrophone() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophone() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                self.microphoneGranted = granted
                if !granted {
                    self.openSystemSettingsMicrophone()
                }
            }
        }
    }

    func requestCamera() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run {
                self.cameraGranted = granted
                if !granted {
                    self.openSystemSettingsCamera()
                }
            }
        }
    }

    /// Prompt the user for accessibility access. The OS will only show the prompt once
    /// per launch; afterwards we direct the user to System Settings.
    func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(opts)
    }

    func openSystemSettingsScreenRecording() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSystemSettingsAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSystemSettingsCamera() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSystemSettingsMicrophone() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
