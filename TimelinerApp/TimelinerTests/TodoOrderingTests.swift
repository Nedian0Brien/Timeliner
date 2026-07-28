import Foundation
import Testing

@testable import Timeliner

/// Guards the rule that a drag on a partly-hidden day must not disturb what is hidden.
///
/// Reachable here and nowhere else: both callers need a SwiftData store to build todos,
/// and the case worth testing — completed rows filtered out of the list being dragged —
/// only shows up once the filter has been on and is turned back off.
@Suite("Todo reordering")
struct TodoOrderingTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    @Test("everything visible: the new order is the order")
    func allVisible() {
        let slots = [a, b, c]
        let assigned = TodoOrdering.renumber(daySlots: slots, visibleInNewOrder: [c, a, b])

        #expect(assigned[c] == 0)
        #expect(assigned[a] == 1)
        #expect(assigned[b] == 2)
    }

    /// The one the views could not be made to exercise.
    @Test("a hidden row keeps its slot while the visible ones swap around it")
    func hiddenRowKeepsItsSlot() {
        // b is hidden, so a drag can only reorder a, c and d.
        let slots = [a, b, c, d]
        let assigned = TodoOrdering.renumber(daySlots: slots, visibleInNewOrder: [d, a, c])

        #expect(assigned[b] == 1, "숨은 행은 자기 자리를 그대로 지켜야 한다")
        // The visible rows are dealt into slots 0, 2 and 3 — the ones they already held.
        #expect(assigned[d] == 0)
        #expect(assigned[a] == 2)
        #expect(assigned[c] == 3)
    }

    @Test("every id of the day gets exactly one order, and the orders are the slots")
    func ordersArePermutationOfSlots() {
        let slots = [a, b, c, d]
        let assigned = TodoOrdering.renumber(daySlots: slots, visibleInNewOrder: [c, a])

        #expect(Set(assigned.keys) == Set(slots))
        #expect(Set(assigned.values) == Set(0..<slots.count))
    }

    @Test("no visible rows leaves every slot where it was")
    func noVisibleRows() {
        let slots = [a, b, c]
        let assigned = TodoOrdering.renumber(daySlots: slots, visibleInNewOrder: [])

        #expect(assigned == [a: 0, b: 1, c: 2])
    }

    @Test("a single visible row cannot move")
    func singleVisibleRow() {
        let slots = [a, b, c]
        let assigned = TodoOrdering.renumber(daySlots: slots, visibleInNewOrder: [b])

        #expect(assigned == [a: 0, b: 1, c: 2])
    }

    /// Defensive rather than reachable: the callers build `visibleInNewOrder` by
    /// permuting a subsequence, so it cannot contain a stranger. If one ever did, the
    /// day's own rows are what must survive.
    @Test("an id that is not part of the day is ignored")
    func strangerIsIgnored() {
        let slots = [a, b]
        let stranger = UUID()
        let assigned = TodoOrdering.renumber(daySlots: slots, visibleInNewOrder: [stranger, a, b])

        #expect(assigned[stranger] == nil)
        #expect(Set(assigned.keys) == Set(slots))
    }
}
