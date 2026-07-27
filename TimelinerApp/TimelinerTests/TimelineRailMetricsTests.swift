import CoreGraphics
import Testing

@testable import Timeliner

/// Guards the one thing that went wrong when the time axis was added: the rail line and
/// the markers threaded onto it drifted apart, because each was positioned by a
/// different expression.
@Suite("Timeline rail alignment")
struct TimelineRailMetricsTests {
    /// Widths chosen to catch the arithmetic rather than the shipping numbers: odd rail
    /// widths and thick lines are where a dropped `/ 2` shows up.
    private static let layouts: [TimelineRailMetrics] = [
        .standard,
        TimelineRailMetrics(railInset: 0, railWidth: 20, lineWidth: 2, cardGap: 4),
        TimelineRailMetrics(railInset: 46, railWidth: 21, lineWidth: 3, cardGap: 0),
        TimelineRailMetrics(railInset: 12.5, railWidth: 7.5, lineWidth: 1, cardGap: 2),
        TimelineRailMetrics(railInset: 120, railWidth: 40, lineWidth: 8, cardGap: 16)
    ]

    @Test("the line is centred on the markers", arguments: layouts)
    func lineIsCentredOnMarkers(layout: TimelineRailMetrics) {
        #expect(layout.lineCenterX == layout.markerCenterX)
    }

    /// The bug was not that the centres disagreed in principle — it was that the line
    /// was offset by its leading edge while markers were placed by their centre, so the
    /// two only matched if the line's thickness was compensated for.
    @Test("the line's leading edge accounts for its own thickness", arguments: layouts)
    func lineLeadingEdgeAccountsForThickness(layout: TimelineRailMetrics) {
        #expect(layout.lineLeadingX == layout.markerCenterX - layout.lineWidth / 2)
        #expect(layout.lineLeadingX + layout.lineWidth == layout.markerCenterX + layout.lineWidth / 2)
    }

    /// The rail has to sit inside its own column. A line that spilled past either edge
    /// would touch the content no matter how well centred it was.
    @Test("the line stays inside the rail column", arguments: layouts)
    func lineStaysInsideRailColumn(layout: TimelineRailMetrics) {
        #expect(layout.lineLeadingX >= layout.railInset)
        #expect(layout.lineLeadingX + layout.lineWidth <= layout.railInset + layout.railWidth)
    }

    /// Cards start after the rail column, never inside it — a card overlapping the rail
    /// would cover the markers it is supposed to sit beside.
    @Test("cards start clear of the rail", arguments: layouts)
    func cardsStartClearOfTheRail(layout: TimelineRailMetrics) {
        #expect(layout.contentLeadingX >= layout.railInset + layout.railWidth)
        #expect(layout.contentLeadingX - (layout.railInset + layout.railWidth) == layout.cardGap)
    }

    /// The now marker's pulse ring is far wider than the rail column. It has to overhang
    /// evenly, or it would drag the eye off centre exactly where the timeline claims to
    /// be most precise.
    @Test("oversized markers overhang evenly", arguments: layouts)
    func oversizedMarkersOverhangEvenly(layout: TimelineRailMetrics) {
        let markerWidth = layout.railWidth + 14
        let overhang = layout.overhang(ofMarkerWidth: markerWidth)

        #expect(overhang == 7)
        let leading = layout.markerCenterX - markerWidth / 2
        let trailing = layout.markerCenterX + markerWidth / 2
        #expect(leading == layout.railInset - overhang)
        #expect(trailing == layout.railInset + layout.railWidth + overhang)
    }

    @Test("a marker narrower than the column does not overhang", arguments: layouts)
    func narrowMarkersDoNotOverhang(layout: TimelineRailMetrics) {
        #expect(layout.overhang(ofMarkerWidth: layout.railWidth) == 0)
        #expect(layout.overhang(ofMarkerWidth: 0) == 0)
    }

    /// The numbers that actually ship. If someone retunes the layout, this is the test
    /// that makes them look at the axis again rather than only the card widths.
    @Test("the shipping layout puts the rail where the rows expect it")
    func shippingLayout() {
        let layout = TimelineRailMetrics.standard
        #expect(layout.markerCenterX == 12)
        #expect(layout.lineLeadingX == 11)
        #expect(layout.contentLeadingX == 34)
    }
}
