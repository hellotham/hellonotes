//
//  BoundedCache.swift
//  HelloNotes
//
//  A map that keeps at most `limit` entries, letting go of the one used
//  longest ago.
//

import Foundation

/// A map of at most `limit` entries: past it, the entry used longest ago goes.
/// Not thread-safe — its owner guards it.
///
/// Written for the transclusion cards, whose cache was emptied outright past
/// 64, so every card on the next page was drawn again (implemented.md §51.36).
nonisolated struct BoundedCache<Key: Hashable, Value> {
    let limit: Int
    private var storage: [Key: Value] = [:]
    /// Keys in order of use, the oldest first. Linear, which at a few dozen
    /// entries costs less than a linked list would.
    private var order: [Key] = []

    init(limit: Int) { self.limit = limit }

    var count: Int { storage.count }

    /// The value for `key`, which counts as a use of it.
    subscript(key: Key) -> Value? {
        mutating get {
            guard let value = storage[key] else { return nil }
            touch(key)
            return value
        }
        set {
            guard let newValue else {
                storage[key] = nil
                order.removeAll { $0 == key }
                return
            }
            storage[key] = newValue
            touch(key)
            while storage.count > limit, let oldest = order.first {
                order.removeFirst()
                storage[oldest] = nil
            }
        }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
