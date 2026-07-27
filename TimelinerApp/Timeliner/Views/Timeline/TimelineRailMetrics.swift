import CoreGraphics

/// The horizontal geometry of the timeline's rail.
///
/// The rail line and every marker threaded onto it are positioned from this one value.
/// They used to be worked out separately — the line from the column widths, each marker
/// from its own row's `HStack` spacing — and since those spacings differed per row kind
/// (6 for schedules and the date header, 2 for records, todos and the now marker), the
/// markers landed 3 to 7 points to the right of the line they were meant to sit on.
///
/// The invariant that keeps them together is `lineCenterX == markerCenterX`, and it
/// holds for any widths because both sides are derived from the same expression. Rows
/// hold up their end by laying their columns out edge to edge: the gap before the
/// content is `cardGap`, never `HStack` spacing, because spacing inserted before the
/// rail column shifts the marker without the line knowing.
struct TimelineRailMetrics: Equatable {
    /// How far the rail column is inset from a row's leading edge.
    ///
    /// Zero now that the times sit above their cards instead of in a column of their
    /// own. It is kept because it is what the line and the markers are both measured
    /// from — collapsing it to a constant would hide the very term that has to agree
    /// between them.
    var railInset: CGFloat
    /// The column the markers fill.
    var railWidth: CGFloat
    /// Thickness of the drawn rail line.
    var lineWidth: CGFloat
    /// Breathing room between the rail column and the content.
    var cardGap: CGFloat

    static let standard = TimelineRailMetrics(
        railInset: 0,
        railWidth: 24,
        lineWidth: 2,
        cardGap: 10
    )

    /// Centre of the rail column, measured from a row's leading edge. Markers fill that
    /// column, so this is where every one of them ends up.
    var markerCenterX: CGFloat {
        railInset + railWidth / 2
    }

    /// Leading edge of the rail line. It is drawn as a `lineWidth`-wide rectangle offset
    /// from the group's leading edge, so it has to be nudged back by half its thickness
    /// to end up centred rather than starting at the centre.
    var lineLeadingX: CGFloat {
        markerCenterX - lineWidth / 2
    }

    var lineCenterX: CGFloat {
        lineLeadingX + lineWidth / 2
    }

    /// Where a row's content — its time line and the card under it — begins.
    var contentLeadingX: CGFloat {
        railInset + railWidth + cardGap
    }

    /// A marker wider than the rail column overhangs it symmetrically, so it stays
    /// centred; this is how far it reaches past either side. The now marker's pulse ring
    /// is the one that does this.
    func overhang(ofMarkerWidth width: CGFloat) -> CGFloat {
        max(0, (width - railWidth) / 2)
    }
}
