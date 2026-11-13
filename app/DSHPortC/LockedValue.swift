import Foundation

/// Copy value snapshots under the same lock that protects mutations.
final class LockedValue<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var snapshot: Value {
        lock.withLock { value }
    }

    func update(_ mutate: (inout Value) -> Void) -> Value {
        lock.withLock {
            mutate(&value)
            return value
        }
    }
}
