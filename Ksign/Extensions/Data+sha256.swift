//
//  Data+SHA256.swift
//  Ksign
//

import Foundation
import CryptoKit

extension Data {
    /// أول 16 حرف من SHA256 hex — يُستخدم كـ UserDefaults key فريد للشهادة
    func sha256HexPrefix() -> String {
        let digest = SHA256.hash(data: self)
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
