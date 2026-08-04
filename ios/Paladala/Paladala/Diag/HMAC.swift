//
//  HMAC.swift
//  Paladala
//
//  HMAC-SHA256 helper used by the Paladala Portal reporter.
//  Must produce byte-for-byte identical output to the Worker's
//  `hmacSha256Hex` in `portal/worker/src/hmac.ts`, otherwise
//  the Worker's `verifyHmac` will return `signature_mismatch`
//  and 401 every request.
//
//  Wire format on the wire:
//    X-Timestamp: <unix-ms>
//    X-Signature: hex( HMAC-SHA256(secret, "${ts}.${body}") )
//
//  The Worker reads `body` as text and signs the same
//  `ts + "." + body` string, so any non-binary JSON payload
//  round-trips identically.
//

import CryptoKit
import Foundation

enum HMACSigner {
    /// HMAC-SHA256 of `data` keyed by `secret`.  Returns lowercase hex.
    /// Matches `portal/worker/src/hmac.ts::hmacSha256Hex` byte-for-byte.
    /// Renamed from `HMAC` to avoid colliding with `CryptoKit.HMAC`
    /// (a generic type).  Callers go through `HMACSigner.sha256Hex(...)`
    /// so the generic name stays available for `HMAC<SHA256>.authenticationCode`.
    static func sha256Hex(secret: String, _ data: Data) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = CryptoKit.HMAC<SHA256>.authenticationCode(for: data, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}