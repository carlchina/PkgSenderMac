import AppKit
import Foundation
import ServiceManagement

/// Launch-at-login.
///
/// macOS 13+ uses `SMAppService.mainApp`; macOS 12 has no `SMAppService`, so
/// the fallback is a per-user LaunchAgent. The agent is written to (and, when
/// disabled, removed from) **only** `com.local.pkgsendermac.plist` — no other
/// LaunchAgent belonging to this user is ever touched.
enum LoginItemManager {
    static let agentLabel = "com.local.pkgsendermac"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(agentLabel).plist")
    }

    /// Path of this executable (used as the agent's program argument).
    static var executablePath: String {
        if let path = Bundle.main.executablePath { return path }
        let argument = CommandLine.arguments.first ?? "PkgSender"
        if argument.contains("/") {
            return URL(fileURLWithPath: argument).standardizedFileURL.path
        }
        return "/usr/local/bin/PkgSender"
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// Returns a user-facing error description on failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return nil
            } catch {
                return "Login item failed: \(error.localizedDescription)"
            }
        }
        return setLegacyEnabled(enabled)
    }

    // MARK: - macOS 12 fallback

    private static func setLegacyEnabled(_ enabled: Bool) -> String? {
        let manager = FileManager.default
        let directory = agentURL.deletingLastPathComponent()
        if enabled {
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                let plist = agentPlist(program: executablePath)
                try plist.write(to: agentURL, atomically: true, encoding: .utf8)
                chmod(agentURL.path, 0o644)
                return nil
            } catch {
                return "Could not write \(agentLabel).plist: \(error.localizedDescription)"
            }
        }
        // Only ever remove our own agent file.
        guard manager.fileExists(atPath: agentURL.path) else { return nil }
        do {
            try manager.removeItem(at: agentURL)
            return nil
        } catch {
            return "Could not remove \(agentLabel).plist: \(error.localizedDescription)"
        }
    }

    static func agentPlist(program: String) -> String {
        let escaped = program
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(escaped)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }
}
