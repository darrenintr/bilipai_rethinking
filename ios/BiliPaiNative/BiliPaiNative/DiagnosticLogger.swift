import Foundation
import Combine

/// DiagnosticLogger for iOS - specialized for tracing complex issues
final class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()
    
    enum Category: String {
        case recommendation = "RECO"
        case playback = "PLAY"
        case fullscreen = "FULL"
        case auth = "AUTH"
        case network = "NETW"
    }
    
    struct Event: Identifiable {
        let id = UUID()
        let timestamp: Date
        let category: Category
        let message: String
        let details: [String: Any]?
        
        func format() -> String {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            let timeStr = df.string(from: timestamp)
            var detailStr = ""
            if let details = details, !details.isEmpty {
                detailStr = " | \(details)"
            }
            return "[\(timeStr)] [\(category.rawValue)] \(message)\(detailStr)"
        }
    }
    
    @Published private(set) var events: [Event] = []
    private let maxEvents = 500
    private let lock = NSLock()
    
    private init() {}
    
    func log(_ category: Category, _ message: String, details: [String: Any]? = nil) {
        let event = Event(timestamp: Date(), category: category, message: message, details: details)
        
        lock.lock()
        defer { lock.unlock() }
        
        // Also log to the main bpLog for general visibility
        bpLog("[\(category.rawValue)] \(message) \(details ?? [:])")
        
        DispatchQueue.main.async {
            self.events.append(event)
            if self.events.count > self.maxEvents {
                self.events.removeFirst()
            }
        }
    }
    
    func generateReport() -> String {
        lock.lock()
        let currentEvents = events
        lock.unlock()
        
        var report = "========================================\n"
        report += "BiliPai iOS Deep Diagnostic Report\n"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        report += "Generated at: \(df.string(from: Date()))\n"
        report += "========================================\n\n"
        
        for event in currentEvents {
            report += event.format() + "\n"
        }
        
        report += "\n========================================\n"
        report += "END OF REPORT\n"
        report += "========================================\n"
        
        return report
    }
    
    func export() -> URL? {
        let report = generateReport()
        let fileName = "BiliPai_Diagnostic_\(Int(Date().timeIntervalSince1970)).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try report.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            print("Failed to export diagnostic report: \(error.localizedDescription)")
            return nil
        }
    }
}

// Global helper for quick logging
func diagLog(_ category: DiagnosticLogger.Category, _ message: String, details: [String: Any]? = nil) {
    DiagnosticLogger.shared.log(category, message, details: details)
}
