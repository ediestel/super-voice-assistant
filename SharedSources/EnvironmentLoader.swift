import Foundation
import SwiftDotenv

/// Shared utility for loading environment variables from .env files.
/// Searches multiple locations to find the .env file regardless of where the executable is run from.
public enum EnvironmentLoader {

    private static var isLoaded = false

    /// Load environment variables from .env file.
    /// Searches in order: executable directory (up to project root), home directory, current directory.
    public static func load() {
        guard !isLoaded else { return }

        // Build search paths starting from executable location going up to project root
        var searchPaths: [String] = []

        if let execPath = Bundle.main.executablePath {
            var dir = (execPath as NSString).deletingLastPathComponent
            searchPaths.append(dir)
            // Go up to find project root (e.g., from .build/arm64-apple-macosx/debug/)
            for _ in 0..<5 {
                dir = (dir as NSString).deletingLastPathComponent
                searchPaths.append(dir)
            }
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        searchPaths.append(homeDir)
        searchPaths.append(FileManager.default.currentDirectoryPath)

        for basePath in searchPaths {
            let envPath = basePath + "/.env"
            if FileManager.default.fileExists(atPath: envPath) {
                do {
                    try Dotenv.configure(atPath: envPath)
                    print("📁 Loaded environment from: \(envPath)")
                    isLoaded = true
                    return
                } catch {
                    // Continue searching
                }
            }
        }
    }

    /// Get an API key, loading .env if needed.
    public static func getApiKey(_ name: String) -> String? {
        // Check environment first (may already be set)
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
            return value
        }

        // Try loading .env
        load()

        // Check again after loading
        if let value = Dotenv[name]?.stringValue, !value.isEmpty {
            return value
        }

        return ProcessInfo.processInfo.environment[name]
    }
}
