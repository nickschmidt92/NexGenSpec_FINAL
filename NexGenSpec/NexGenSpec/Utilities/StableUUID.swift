//
//  StableUUID.swift
//  NexGenSpec
//
//  Deterministic UUID from seed for stable sync IDs across template re-import.
//

import Foundation
import CryptoKit

enum StableUUID {

    /// Returns a deterministic UUID from a seed string (e.g. "jobId-section-sectionId").
    static func from(seed: String) -> UUID {
        let hash = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(hash.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
