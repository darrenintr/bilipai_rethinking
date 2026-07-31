//
//  CDNAkamProbe.swift
//  Paladala
//
//  Network probing primitives used by `CDNManager` to find
//  the lowest-latency B站 media edge. Modelled on the
//  Python `miyouzi/akamTester` repo's TLS-handshake timing
//  approach: a probe establishes a fresh TCP + TLS connection
//  to the *resolved* IP of a known B站 CDN host and reports
//  the wall-clock duration from `connect()` start to TLS
//  handshake `ready`. That number is the closest simulator
//  iOS can produce of "what will my first AVPlayer segment
//  fetch feel like" without paying for an actual byte
//  download.
//
//  Two pieces:
//
//  * `DNSResolver` — `CFHost`-backed A/AAAA lookup. iOS does
//    not expose `getaddrinfo` directly; `CFHost` is the
//    lowest-level public surface and the system DNS resolver
//    already implements the smarts (DoH, multi-resolver
//    round-robin, etc.) we want.
//
//  * `TLSHandshakeProbe` — `Network.framework` connection
//    with `sec_protocol_options_set_server_name` so the SNI
//    matches the host even when we connect by IP. Without the
//    explicit SNI, B站's CDN edge would refuse the handshake
//    (its cert is issued for `*.akamaized.net`, not the
//    resolved IP). The probe also has a hard 5-second
//    timeout so a hung edge cannot block the whole test run.
//

import Foundation
import Network
import CFNetwork

// `sec_protocol_options_set_server_name` is a C function
// declared in `<Security/SecProtocolOptions.h>`. Apple's
// iOS Security umbrella module does NOT re-export it in
// Swift (the umbrella module map covers the keychain /
// certificate / trust APIs but not the network-protocol
// helpers). Even with `import Security` the call resolves
// to "cannot find X in scope" at compile time.
//
// The C symbol IS present in the Security dylib — the
// header just doesn't get re-exported. We work around this
// by declaring a Swift shim with `@_silgen_name` that
// resolves the C symbol at link time directly, bypassing
// the Swift import system. The `sec_protocol_options_t`
// type itself is exposed by `import Network` (via
// `NWProtocolTLS.Options.securityProtocolOptions`).
@_silgen_name("sec_protocol_options_set_server_name")
private func _sec_protocol_options_set_server_name(
    _ options: OpaquePointer,
    _ server_name: CFString
)

// MARK: - DNS resolution

enum DNSResolver {
    /// Resolve `hostname` to its system-DNS A/AAAA records.
    /// Returns IPv4 first (B站's CDN edges are dual-stack
    /// but iOS picks IPv4 by default for `NWConnection`,
    /// and the probe targets the IPv4 path), then IPv6.
    /// Returns an empty array on any failure — the caller
    /// should treat that as "host is unreachable" and
    /// skip the probe.
    ///
    /// The work runs in a `Task.detached` because `CFHost`
    /// is a synchronous Core Foundation API; calling it
    /// from a `@MainActor` method would block the run
    /// loop for the duration of the resolver round-trip
    /// (typically 10-50 ms, but the system resolver can
    /// block up to several seconds when one of its
    /// upstream servers is slow).
    static func resolveIPv4(_ hostname: String) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            // `CFHostCreateWithName` returns `Unmanaged<CFHost>!`
            // (an implicitly-unwrapped optional), not a regular
            // `Optional<...>`, so `guard let ... else { return [] }`
            // fails to compile ("initializer for conditional
            // binding must have Optional type"). The API only
            // produces a non-nil value for a non-nil name input
            // (we pass `hostname as CFString` which is non-nil
            // for any non-empty Swift `String`), so we just take
            // the retained value directly.
            let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
            // `CFHostStartInfoResolution` with a `nil` completion
            // callback runs synchronously. Returns false on
            // resolution failure (e.g. NXDOMAIN).
            guard CFHostStartInfoResolution(host, .addresses, nil) else {
                return []
            }
            guard let cfAddresses = CFHostGetAddressing(host, nil) else {
                return []
            }
            let addressData = cfAddresses.takeUnretainedValue() as? [Data] ?? []
            return Self.parse(addressData: addressData, preferFamily: AF_INET)
        }.value
    }

    /// Pull IPv4 strings out of a `[Data]` of `sockaddr`
    /// blobs. `AF_INET` first, `AF_INET6` after, in the
    /// order `CFHost` emits them — callers that only want
    /// IPv4 should pass `AF_INET` here.
    private static func parse(addressData: [Data], preferFamily: Int32) -> [String] {
        var v4: [String] = []
        var v6: [String] = []
        for data in addressData {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                // `sa_family` is `sa_family_t` (UInt8) on iOS,
                // but `AF_INET` / `AF_INET6` are `Int32`
                // constants. A direct `switch family { case
                // AF_INET: ... }` fails to compile ("expression
                // pattern of type 'Int32' cannot match values
                // of type 'sa_family_t'"). Cast the family to
                // `Int32` for the switch (it's a tiny enum so
                // the conversion is zero-cost and total).
                switch Int32(sa.pointee.sa_family) {
                case AF_INET:
                    var addr = sockaddr_in()
                    memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(buf.count)) != nil {
                        v4.append(String(cString: buf))
                    }
                case AF_INET6:
                    var addr = sockaddr_in6()
                    memcpy(&addr, sa, MemoryLayout<sockaddr_in6>.size)
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    if inet_ntop(AF_INET6, &addr.sin6_addr, &buf, socklen_t(buf.count)) != nil {
                        v6.append(String(cString: buf))
                    }
                default:
                    break
                }
            }
        }
        return preferFamily == AF_INET ? (v4 + v6) : (v6 + v4)
    }
}

// MARK: - TLS handshake probe

struct TLSProbeResult: Sendable, Hashable {
    let ip: String
    let host: String
    let latencyMs: Int?
    let statusCode: Int?  // not meaningful for raw TLS; always nil today
    let error: String?
    var isReachable: Bool { latencyMs != nil && error == nil }
}

enum TLSHandshakeProbe {
    /// Open a fresh TCP + TLS connection to `ip:port` with
    /// the SNI set to `host`, and report the wall-clock
    /// duration of the handshake. The connection is
    /// `cancel()`-ed as soon as `.ready` fires (we don't
    /// need to send a request — the handshake latency is
    /// the whole point of the probe).
    ///
    /// The 5-second timeout is a hard wall: a hung edge
    /// cannot block the test run past that. `URLSession`
    /// does not expose a clean per-attempt deadline for
    /// raw TLS connections, which is why we use
    /// `Network.framework` and a `Task.sleep` for the
    /// timeout (the `NWConnection` itself does not honour
    /// a deadline on TCP / TLS connect).
    static func probe(
        ip: String,
        host: String,
        port: UInt16 = 443,
        timeout: TimeInterval = 5
    ) async -> TLSProbeResult {
        let nwHost = NWEndpoint.Host(ip)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return TLSProbeResult(ip: ip, host: host, latencyMs: nil, statusCode: nil,
                                 error: "invalid port \(port)")
        }
        // TLS options with explicit SNI. Without this the
        // ClientHello would carry the *IP* as the SNI,
        // B站's CDN would reject it (cert is for
        // `*.akamaized.net`, not the IP), and the probe
        // would return `NSURLErrorServerCertificateUntrusted`
        // even on a perfectly healthy edge.
        let tlsOptions = NWProtocolTLS.Options()
        // `tlsOptions.securityProtocolOptions` is a
        // `sec_protocol_options_t` (an opaque pointer) — pass
        // it through as an `OpaquePointer` to match the
        // `@_silgen_name` shim. The `host as CFString` cast
        // is required because the underlying C function
        // takes `CFStringRef`, not a Swift `String`.
        _sec_protocol_options_set_server_name(
            OpaquePointer(tlsOptions.securityProtocolOptions),
            host as CFString
        )
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(to: NWEndpoint.hostPort(host: nwHost, port: nwPort),
                                      using: parameters)

        let started = ContinuousClock.now
        let latch = ResumeLatch()
        return await withCheckedContinuation { (continuation: CheckedContinuation<TLSProbeResult, Never>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = ContinuousClock.now - started
                    let ms = Int(
                        elapsed.components.seconds * 1_000
                        + elapsed.components.attoseconds / 1_000_000_000_000_000
                    )
                    connection.cancel()
                    // `_ =` silences the "result of call to
                    // 'tryResume' is unused" warning — the Bool
                    // return value is meaningful for the timeout
                    // path (where two callers race) but in
                    // `.ready` / `.failed` we're the only
                    // candidate to fire the latch.
                    _ = latch.tryResume {
                        continuation.resume(returning: TLSProbeResult(
                            ip: ip, host: host,
                            latencyMs: max(ms, 1),
                            statusCode: nil, error: nil
                        ))
                    }
                case .failed(let err):
                    connection.cancel()
                    _ = latch.tryResume {
                        continuation.resume(returning: TLSProbeResult(
                            ip: ip, host: host,
                            latencyMs: nil, statusCode: nil,
                            error: err.localizedDescription
                        ))
                    }
                case .cancelled:
                    // The timeout task will surface a "timed
                    // out" result if we never made it to
                    // `.ready`/`.failed`. Nothing to do here.
                    break
                default:
                    break
                }
            }
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if latch.tryResume({}) {
                    connection.cancel()
                    continuation.resume(returning: TLSProbeResult(
                        ip: ip, host: host,
                        latencyMs: nil, statusCode: nil,
                        error: "timed out after \(Int(timeout))s"
                    ))
                }
            }
            // Start the connection. The stateUpdateHandler
            // will fire on the queue below, dispatching
            // continuation resumes onto a known queue (the
            // default `.global()` is fine for a probe — we
            // don't care which executor picks up the resume).
            connection.start(queue: .global())
            // `connection` is captured by the closures above;
            // keep the lifetime alive until at least one of
            // them has fired.
            _ = timeoutTask
        }
    }
}

// MARK: - Resume latch

/// `withCheckedContinuation` is "resuming once" only by
/// convention — if two paths both try to resume (e.g. the
/// `.ready` callback and the timeout task), the runtime
/// traps. This latch makes the "resume once" semantics
/// explicit. Marked `@unchecked Sendable` because the only
/// mutable state is `resumed`, guarded by a lock; the
/// continuation itself is captured only inside the
/// `tryResume` closure, never copied.
private final class ResumeLatch: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()
    func tryResume(_ block: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        block()
        return true
    }
}
