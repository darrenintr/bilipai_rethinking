import Foundation
import SwiftUI

final class Logger: ObservableObject {
    static let shared = Logger()
    
    @Published private(set) var logs: [String] = []
    private let maxLogs = 1000
    
    private init() {}
    
    func log(_ message: String, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] [\(fileName):\(line)] \(message)"
        
        DispatchQueue.main.async {
            self.logs.append(logEntry)
            if self.logs.count > self.maxLogs {
                self.logs.removeFirst()
            }
            // Also print to console
            print(logEntry)
        }
    }
    
    func export() -> URL? {
        let allLogs = logs.joined(separator: "\n")
        let fileName = "BiliPai_Logs_\(Int(Date().timeIntervalSince1970)).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try allLogs.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            log("Failed to export logs: \(error.localizedDescription)")
            return nil
        }
    }
}

// Global helper for logging
func bpLog(_ message: String, file: String = #file, line: Int = #line) {
    Logger.shared.log(message, file: file, line: line)
}
