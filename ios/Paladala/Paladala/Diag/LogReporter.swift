//
//  LogReporter.swift
//  Paladala
//
//  Buffer + sign + POST + retry for `POST /v1/report` against
//  the Paladala Portal Worker.  Sibling to `TelegramLogReporter`
//  but talks to the Worker's HMAC-authenticated ingest endpoint
//  instead of the public Telegram Bot API.
//
//  Lifecycle:
//    - `start()` is called from `PaladalaApp.init()` (no-op
//      when toggle is off or secret is empty).
//    - `ingest(...)` is called from `ErrorSink` (fire-and-forget).
//    - A periodic flush task drains the queue every 30s.
//    - `stop()` is called when the user flips the toggle off.
//

import Foundation

actor LogReporter {
    static let shared = LogReporter()

    /// Per-launch UUID; in-memory only.  Matches the Worker's
    /// interpretation of `session_id` as a label, not a stable
    /// identity across launches.
    nonisolated let currentSessionID = UUID().uuidString

    private var queue: [ReportPayload] = []
    private var flushTask: Task<Void, Never>?
    /// Cap to bound memory under prolonged outages.
    private let queueCapacity = 1000

    func start() {
        guard LogReporterConfig.enabled,
              !LogReporterConfig.sharedSecret.isEmpty
        else { return }
        flushTask?.cancel()
        flushTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(LogReporterConfig.flushInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.flush()
            }
        }
    }

    func stop() {
        flushTask?.cancel()
        flushTask = nil
    }

    func ingest(_ payload: ReportPayload) {
        guard LogReporterConfig.enabled,
              !LogReporterConfig.sharedSecret.isEmpty
        else { return }
        if queue.count >= queueCapacity {
            queue.removeFirst()
        }
        queue.append(payload)
    }

    /// Drain up to `batchSize` events, sign, POST with retries.
    /// On 2xx: drop batch.  On 401: self-disable.  On 403:
    /// drop batch (build_too_old).  On 5xx/4xx/network: re-queue
    /// after backoff.
    private func flush() async {
        guard !queue.isEmpty else { return }
        let batch = Array(queue.prefix(LogReporterConfig.batchSize))
        queue.removeFirst(min(batch.count, queue.count))

        guard let body = try? JSONEncoder().encode(batch) else {
            bpLog("LogReporter: failed to encode batch — dropping")
            return
        }
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let signingInput = Data("\(ts).".utf8) + body
        let signature = HMACSigner.sha256Hex(secret: LogReporterConfig.sharedSecret, signingInput)

        // Attempt 1 is immediate; subsequent attempts back off
        // 1s / 4s / 16s.  Each attempt reuses the same body +
        // signature (signature is over timestamp, not over each
        // attempt).
        let backoffs: [TimeInterval] = [0, 1, 4, 16]
        for attempt in 1...backoffs.count {
            if attempt > 1 {
                let delay = backoffs[attempt - 1]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            var req = URLRequest(url: LogReporterConfig.endpoint.appendingPathComponent("v1/report"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(String(ts), forHTTPHeaderField: "X-Timestamp")
            req.setValue(signature, forHTTPHeaderField: "X-Signature")
            req.setValue(LogReporterConfig.userAgent, forHTTPHeaderField: "User-Agent")
            req.httpBody = body
            req.timeoutInterval = LogReporterConfig.requestTimeout

            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse {
                    switch http.statusCode {
                    case 200:
                        return  // success; batch dropped
                    case 401:
                        bpLog("CRITICAL: LogReporter 401 — secret mismatch; disabling")
                        stop()
                        return
                    case 403:
                        bpLog("LogReporter 403 (build_too_old); dropping batch")
                        return
                    default:
                        continue  // 5xx / 4xx: retry
                    }
                }
                continue  // non-HTTP response: retry
            } catch {
                continue  // network error: retry
            }
        }
        // All retries exhausted — put batch back at front of
        // queue so the next flush picks it up.
        queue.insert(contentsOf: batch, at: 0)
        if queue.count > queueCapacity {
            queue.removeFirst(queue.count - queueCapacity)
        }
        bpLog("LogReporter: batch failed after retries; re-queued (\(batch.count) events)")
    }
}