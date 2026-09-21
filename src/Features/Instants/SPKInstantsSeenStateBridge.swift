import Foundation

/// Rewrites Instagram's in-memory Instants seen set.
///
/// `IGQuickSnapStore.seenSnapPks` is a Swift `Set<String>` stored property. Instagram 448
/// stopped exporting the `@objc` reload that rebuilt it from the persisted seen key, and an
/// NSSet written into the ivar from Objective-C is not safe: Instagram's Swift code reads the
/// storage as native and faults. Assigning through Swift's own `Set` keeps the native layout
/// and releases the old storage correctly.
@objc(SPKInstantsSeenStateBridge)
final class SPKInstantsSeenStateBridge: NSObject {
    /// Replaces the `Set<String>` stored at `address` with `values`.
    ///
    /// The caller guarantees `address` is the storage of a live `Set<String>` ivar and that
    /// Instagram is not accessing it concurrently (main thread).
    @objc static func replaceStringSet(atAddress address: UnsafeMutableRawPointer, with values: [String]) {
        address.assumingMemoryBound(to: Set<String>.self).pointee = Set(values)
    }
}
