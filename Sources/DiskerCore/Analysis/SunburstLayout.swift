import Foundation

/// One drawable wedge.
public struct SunburstSegment: Sendable, Identifiable {
    public let id: Int
    public let node: FileNode
    /// 0 is the innermost ring drawn around the hub.
    public let ring: Int
    /// Radians, clockwise from 12 o'clock.
    public let startAngle: Double
    public let endAngle: Double
    public let category: StorageCategory
    /// Path components from the chart root down to this node, for Finder reveal and drill-down.
    public let components: [String]

    public var sweep: Double { endAngle - startAngle }
    public var midAngle: Double { (startAngle + endAngle) / 2 }
}

/// Turns a scanned tree into ring geometry.
///
/// Two limits keep this tractable and legible. Wedges thinner than `minimumAngle` are merged
/// into a trailing "other" wedge — below roughly half a degree a wedge is a hairline that
/// cannot be clicked or understood, and a full volume would otherwise produce hundreds of
/// thousands of them. Depth is capped at `maxRings` because rings past the fourth are only a
/// few points wide.
public enum SunburstLayout {

    public struct Options: Sendable {
        public var maxRings: Int
        /// Radians. Default ≈ 0.6°.
        public var minimumAngle: Double

        public init(maxRings: Int = 4, minimumAngle: Double = 0.011) {
            self.maxRings = maxRings
            self.minimumAngle = minimumAngle
        }
    }

    public static func build(
        root: FileNode,
        rootComponents: [String] = [],
        options: Options = Options()
    ) -> [SunburstSegment] {
        var segments: [SunburstSegment] = []
        var nextID = 0

        func emit(
            children: [FileNode],
            ring: Int,
            from startAngle: Double,
            to endAngle: Double,
            parentTotal: UInt64,
            components: [String]
        ) {
            guard ring < options.maxRings, parentTotal > 0 else { return }

            let available = endAngle - startAngle
            var cursor = startAngle
            var mergedSize: UInt64 = 0
            var mergedCount = 0

            for child in children {
                let sweep = available * (Double(child.size) / Double(parentTotal))
                if sweep < options.minimumAngle {
                    // Too thin to draw or click. Accumulate rather than discard so the ring
                    // still spans the parent's full arc and the sizes stay honest.
                    mergedSize &+= child.size
                    mergedCount += child.fileCount
                    continue
                }

                let childComponents = components + [child.name]
                let segment = SunburstSegment(
                    id: nextID,
                    node: child,
                    ring: ring,
                    startAngle: cursor,
                    endAngle: cursor + sweep,
                    category: StorageCategory.classify(components: childComponents),
                    components: childComponents
                )
                segments.append(segment)
                nextID += 1

                if !child.children.isEmpty {
                    emit(
                        children: child.children,
                        ring: ring + 1,
                        from: cursor,
                        to: cursor + sweep,
                        parentTotal: child.size,
                        components: childComponents
                    )
                }
                cursor += sweep
            }

            if mergedSize > 0, cursor < endAngle {
                let node = FileNode(
                    name: "\(mergedCount) smaller items",
                    size: mergedSize,
                    kind: .aggregate,
                    fileCount: mergedCount
                )
                segments.append(
                    SunburstSegment(
                        id: nextID,
                        node: node,
                        ring: ring,
                        startAngle: cursor,
                        endAngle: endAngle,
                        category: .other,
                        components: components
                    ))
                nextID += 1
            }
        }

        emit(
            children: root.children,
            ring: 0,
            from: 0,
            to: 2 * .pi,
            parentTotal: root.size,
            components: rootComponents
        )
        return segments
    }

    /// Finds the wedge under a point expressed relative to the chart centre.
    ///
    /// Converts to polar coordinates and looks up the ring directly, so cost is independent
    /// of how many wedges are drawn — hit-testing thousands of paths per mouse-move would
    /// not hold 60fps.
    public static func segment(
        at offset: (x: Double, y: Double),
        in segments: [SunburstSegment],
        innerRadius: Double,
        ringWidth: Double
    ) -> SunburstSegment? {
        let radius = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        guard radius > innerRadius else { return nil }

        let ring = Int((radius - innerRadius) / ringWidth)

        // atan2 measured clockwise from 12 o'clock, normalised to 0..2π to match layout.
        var angle = atan2(offset.x, -offset.y)
        if angle < 0 { angle += 2 * .pi }

        return segments.first {
            $0.ring == ring && angle >= $0.startAngle && angle < $0.endAngle
        }
    }
}
