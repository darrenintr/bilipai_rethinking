//
//  CDNAkamProbe.swift
//  Paladala
//
//  Network probing primitive used by `CDNManager` to find the
//  lowest-latency B站 media edge. Modelled on the Python
//  `miyouzi/akamTester` repo's TLS-handshake timing approach:
//  a probe establishes a fresh TCP + TLS connection to a known
//  B站 CDN host and reports the wall-clock duration from
//  `connect()` start to TLS handshake `.ready`. That number is
//  the closest simulator iOS can produce of "what will my
//  first AVPlayer segment fetch feel like" without paying for
//  an actual byte download.
//
//  Design choice — host-based, not IP-based
//  ----------------------------------------
//  The Python `akamTester` resolves a host to its IPs and
//  probes each IP with `sec_protocol_options_set_server_name`
//  (so the SNI is the host, not the IP). iOS does NOT export
//  that C function at link time even though it's in the
//  Security framework's public header — building an iOS app
//  that calls it produces "Undefined symbols for architecture
//  arm64: _sec_protocol_options_set_server_name" at the
//  linker step (verified on iOS 18.5 SDK with Xcode 16.4).
//
//  We therefore drop the per-IP leg and let `NWConnection`
//  connect to the host string directly. iOS's system DNS
//  resolves the host to one (or more) IPs and picks the
//  nearest anycast PoP for the user's network. For akamai
//  edges — which is the host pool where per-IP selection
//  would have mattered most — this is "close enough":
//  geographic IP routing still happens inside the network
//  stack, just inside the resolver rather than inside our
//  code. The SNI in the ClientHello is the host (the system
//  fills it in from the URL host), so cert validation against
//  `*.akamaized.net` works without any explicit SNI tweak.
//

import Foundation
import Network

// MARK: - TLS handshake probe

struct TLSProbeResult: Sendable, Hashable {
    let host: String
    let latencyMs: Int?
    let statusCode: Int?  // not meaningful for raw TLS; always nil today
    let error: String?
    var isReachable: Bool { latencyMs != nil && error == nil }
}

enum TLSHandshakeProbe {
    /// Open a fresh TCP + TLS connection to `host:port` and
    /// report the wall-clock duration of the handshake. The
    /// connection is `cancel()`-ed as soon as `.ready` fires
    /// (we don't need to send a request — the handshake
    /// latency is the whole point of the probe).
    ///
    /// The 5-second timeout is a hard wall: a hung edge
    /// cannot block the test run past that. `URLSession` does
    /// not expose a clean per-attempt deadline for raw TLS
    /// connections, which is why we use `Network.framework`
    /// and a `Task.sleep` for the timeout (the `NWConnection`
    /// itself does not honour a deadline on TCP / TLS
    /// connect).
    static func probe(
        host: String,
        port: UInt16 = 443,
        timeout: TimeInterval = 5
    ) async -> TLSProbeResult {
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return TLSProbeResult(host: host, latencyMs: nil, statusCode: nil,
                                  error: "invalid port \(port)")
        }
        // iOS fills the SNI in from the host string
        // automatically, and validates the cert against the
        // matching name — so `host` MUST be the domain (e.g.
        // `upos-sz-mirrorali.bilivideo.com`), not an IP. The
        // cert is issued for `*.akamaized.net` /
        // `*.bilivideo.com`, so an IP in the SNI would fail
        // handshake. `NWProtocolTLS.Options()` defaults are
        // what we want — no `@_silgen_name` hack needed,
        // unlike the macOS `sec_protocol_options_set_server_name`
        // approach (which iOS doesn't export at link time).
        let tlsOptions = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(to: .hostPort(host: nwHost, port: nwPort),
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
                            host: host,
                            latencyMs: max(ms, 1),
                            statusCode: nil, error: nil
                        ))
                    }
                case .failed(let err):
                    connection.cancel()
                    _ = latch.tryResume {
                        continuation.resume(returning: TLSProbeResult(
                            host: host,
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
                        host: host,
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

// MARK: - Akamai anycast IP seed list

/// Known-good anycast IPs for the B站 海外 Akamai edge
/// (`upos-hz-mirrorakam.akamaized.net`). Seed list — we
/// **do not** probe these directly today because iOS
/// blocks per-IP TLS probing:
///
///   1. The C function `sec_protocol_options_set_server_name`
///      is declared in `<Security/SecProtocolOptions.h>`
///      (iOS 13+) but **not exported by the iOS Security
///      dylib** — building an app that calls it produces
///      `Undefined symbols for architecture arm64:
///      _sec_protocol_options_set_server_name` at the
///      linker step (verified on iOS 18.5 SDK with
///      Xcode 16.4).
///   2. `URLSession` derives the SNI from the URL host. If
///      we substitute one of these IPs into the URL, the
///      `ClientHello` SNI is the IP and B站's edge (cert
///      is for `*.akamaized.net`) rejects the handshake.
///
/// Both gates close the "static IP list + latency test +
/// SNI-pinned TCP" path that the desktop
/// [BugKun/akam-proxy](https://github.com/BugKun/akam-proxy)
/// (Node.js) and the Python
/// [miyouzi/akamTester](https://github.com/miyouzi/akamTester)
/// repos implement. We resolve the problem on iOS by
/// letting `NWConnection` connect to the **host string**
/// instead — iOS's system DNS already does PoP-aware
/// anycast routing for akamai edges (see
/// `TLSHandshakeProbe.probe(host:)` above), and SNI is
/// filled in from the host for free.
///
/// So this list is **dormant today** — kept on disk so a
/// future `Network.framework` rewrite of the proxy's
/// upstream fetcher (one that uses raw
/// `sec_protocol_options_t` *or* an `NWConnection` per IP
/// with the host baked into the SNI via a workaround for
/// the missing symbol) has a concrete seed to start from.
/// The list itself is taken verbatim from
/// `akam-proxy`'s `ip_list.txt` (BugKun, 22⭐, last
/// touched 2020) — those are the IPs the community
/// measured as responding to the akamai anycast for the
/// B站 海外 mirror. Freshness is unverified; the project
/// has been quiet for years and some entries may be
/// recycled.
///
/// `nonisolated(unsafe)` is required because the array
/// itself is `Sendable` (`[String]` is value-typed and
/// immutable) but the `static let` initialiser is a
/// process-wide singleton that any isolation domain can
/// reach; Swift 6's strict concurrency rejects the
/// default `nonisolated` for globals that aren't
/// compile-time `let`. The contents are never mutated.
nonisolated(unsafe) enum AkamaiIPSeedList {
    static let ips: [String] = [
        "202.183.253.8",
        "195.175.116.41",
        "202.183.253.9",
        "95.101.128.104",
        "23.222.29.240",
        "23.63.74.42",
        "23.34.61.139",
        "95.101.128.96",
        "182.176.156.18",
        "23.15.179.193",
        "23.15.179.138",
        "200.136.36.162",
        "210.55.204.218",
        "109.105.109.32",
        "23.222.29.208",
        "203.106.94.24",
        "23.48.39.26",
        "24.156.130.185",
        "146.88.61.8",
        "146.88.61.9",
        "182.176.156.82",
        "110.93.233.11",
        "23.215.131.184",
        "23.209.183.16",
        "182.176.156.104",
        "104.96.221.168",
        "63.243.242.232",
        "23.206.194.35",
        "193.140.13.73",
        "193.140.13.81",
        "203.13.161.9",
        "67.69.196.139",
        "23.32.3.81",
        "204.237.143.16",
        "63.243.242.218",
        "124.124.252.19",
        "104.80.88.81",
        "24.156.130.186",
        "172.232.0.146",
        "2.16.106.49",
        "23.219.93.27",
        "95.101.1.99",
        "210.55.204.208",
        "124.155.223.104",
        "23.215.131.194",
        "59.167.22.34",
        "163.28.5.8",
        "188.43.72.40",
        "2.16.106.104",
        "200.136.36.163",
        "23.63.74.18",
        "23.34.61.152",
        "110.93.233.17",
        "195.175.116.18",
        "67.69.196.154",
        "188.43.72.18",
        "109.105.109.24",
        "95.101.0.107",
        "110.164.253.145",
        "23.209.183.11",
        "23.219.93.33",
        "59.167.22.81",
        "172.232.0.160",
        "203.106.94.11",
        "204.237.143.88",
        "23.32.3.91",
        "104.80.88.120",
        "163.28.5.25",
        "104.96.221.185",
        "203.13.161.10",
        "182.176.156.56",
        "110.164.253.152",
        "124.155.223.118",
        "23.206.194.33",
        "124.124.252.24",
    ]
}
