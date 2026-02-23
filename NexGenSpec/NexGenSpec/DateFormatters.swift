//
//  DateFormatters.swift
//  NexGenSpec
//

import Foundation

enum DateFormatters {

    static let mediumDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()
}
