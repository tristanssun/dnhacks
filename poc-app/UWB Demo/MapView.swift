import SwiftUI

struct MapView: View {
    @ObservedObject var model: TacticalMapModel
    var yaw: Float
    var heading: Float
    var hasPeers: Bool

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: false)) { timeline in
                Canvas { context, size in
                    perfCounters.recordUIFrame()
                    drawMap(
                        in: &context,
                        size: size,
                        time: timeline.date.timeIntervalSinceReferenceDate
                    )
                }
            }
            .onAppear {
                model.setAspect(proxy.size.height / max(proxy.size.width, 1))
            }
            .onChange(of: proxy.size) { _, size in
                model.setAspect(size.height / max(size.width, 1))
            }
        }
        .clipped()
    }

    private struct Marker {
        let track: TacticalMapModel.Track
        let point: CGPoint
        let rawPoint: CGPoint
        let isClamped: Bool
        let rotation: Float
        let markerColor: Color
        let labelColor: Color
        let opacity: Double
        let hasFacing: Bool
        var labelRect = CGRect.zero
        var labelRightAligned = false
    }

    private func drawMap(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let halfWidth = animatedHalfWidth(at: time)
        let pointsPerMetre = (size.width / 2) / CGFloat(max(halfWidth, 0.001))

        drawGrid(in: &context, size: size, centre: centre, pointsPerMetre: pointsPerMetre)
        drawCrosshair(in: &context, size: size, centre: centre)
        drawCornerBrackets(in: &context, size: size)

        var markers = resolvedMarkers(
            size: size,
            centre: centre,
            pointsPerMetre: pointsPerMetre,
            time: time
        )
        placeLabels(&markers, in: context, size: size)
        drawMarkers(markers, in: &context, centre: centre, pointsPerMetre: pointsPerMetre)

        drawSelfMarker(in: &context, centre: centre, time: time)
        drawScaleBar(in: &context, size: size, pointsPerMetre: pointsPerMetre)
        drawCompass(in: &context, size: size)

        if !hasPeers {
            drawEmptyState(in: &context, centre: centre, time: time)
        }
    }

    private func animatedHalfWidth(at time: TimeInterval) -> Float {
        let raw = min(max((time - model.scaleAnimStart) / 0.6, 0), 1)
        let eased = Float(1 - pow(1 - raw, 3))
        return model.previousHalfWidthMeters
            + (model.halfWidthMeters - model.previousHalfWidthMeters) * eased
    }

    private func drawGrid(
        in context: inout GraphicsContext,
        size: CGSize,
        centre: CGPoint,
        pointsPerMetre: CGFloat
    ) {
        let spacing = CGFloat(gridFeet) * 0.3048 * pointsPerMetre
        guard spacing >= 0.5 else { return }

        let horizontalCount = Int(ceil(size.width / (2 * spacing))) + 1
        for index in (-horizontalCount)...horizontalCount where index != 0 {
            let x = snapped(centre.x + CGFloat(index) * spacing)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            let color = index.isMultiple(of: 5) ? Theme.line.opacity(0.6) : Theme.grid
            context.stroke(line, with: .color(color), lineWidth: 1)
        }

        let verticalCount = Int(ceil(size.height / (2 * spacing))) + 1
        for index in (-verticalCount)...verticalCount where index != 0 {
            let y = snapped(centre.y + CGFloat(index) * spacing)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            let color = index.isMultiple(of: 5) ? Theme.line.opacity(0.6) : Theme.grid
            context.stroke(line, with: .color(color), lineWidth: 1)
        }
    }

    private func drawCrosshair(in context: inout GraphicsContext, size: CGSize, centre: CGPoint) {
        let x = snapped(centre.x)
        let y = snapped(centre.y)
        let halfGap: CGFloat = 9

        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: centre.x - halfGap, y: y))
        path.move(to: CGPoint(x: centre.x + halfGap, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: centre.y - halfGap))
        path.move(to: CGPoint(x: x, y: centre.y + halfGap))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(Theme.line), lineWidth: 1)
    }

    private func drawCornerBrackets(in context: inout GraphicsContext, size: CGSize) {
        let inset: CGFloat = 12
        let length: CGFloat = 14
        let left = snapped(inset)
        let right = snapped(size.width - inset)
        let top = snapped(inset)
        let bottom = snapped(size.height - inset)
        var path = Path()

        path.move(to: CGPoint(x: left, y: top + length))
        path.addLine(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left + length, y: top))
        path.move(to: CGPoint(x: right - length, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: top + length))
        path.move(to: CGPoint(x: left, y: bottom - length))
        path.addLine(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left + length, y: bottom))
        path.move(to: CGPoint(x: right - length, y: bottom))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right, y: bottom - length))
        context.stroke(path, with: .color(Theme.inkFaint), lineWidth: 1)
    }

    private func resolvedMarkers(
        size: CGSize,
        centre: CGPoint,
        pointsPerMetre: CGFloat,
        time: TimeInterval
    ) -> [Marker] {
        model.tracks.sorted { $0.distance > $1.distance }.map { track in
            let mapPosition = track.mapPosition(at: time)
            let body = TacticalMapModel.mapToBody(mapPosition, yaw: yaw)
            var rawPoint = CGPoint(
                x: centre.x + CGFloat(body.right) * pointsPerMetre,
                y: centre.y - CGFloat(body.forward) * pointsPerMetre
            )
            if !track.hasBearing {
                rawPoint = CGPoint(x: centre.x, y: centre.y - CGFloat(track.distance) * pointsPerMetre)
            }

            let point: CGPoint
            let isClamped: Bool
            if track.hasBearing {
                point = CGPoint(
                    x: min(max(rawPoint.x, 18), max(size.width - 18, 18)),
                    y: min(max(rawPoint.y, 18), max(size.height - 18, 18))
                )
                isClamped = point != rawPoint
            } else {
                point = rawPoint
                isClamped = false
            }

            let facing = track.facing(at: time)
            let colors = markerColors(for: track, hasFacing: facing != nil)
            let clampedOpacity = isClamped ? 0.6 : 1.0
            return Marker(
                track: track,
                point: point,
                rawPoint: rawPoint,
                isClamped: isClamped,
                rotation: facing.map { yaw - $0 } ?? 0,
                markerColor: colors.marker,
                labelColor: colors.label,
                opacity: track.opacity(at: time) * clampedOpacity,
                hasFacing: facing != nil
            )
        }
    }

    private func markerColors(
        for track: TacticalMapModel.Track,
        hasFacing: Bool
    ) -> (marker: Color, label: Color) {
        if track.hasBearing, !hasFacing {
            return (Theme.inkFaint, Theme.ink)
        }
        switch track.source {
        case .live:
            return (Theme.ink, Theme.ink)
        case .aging:
            return (Theme.inkDim, Theme.ink)
        case .relayed:
            return (Theme.frost, Theme.frost)
        case .inferred, .none:
            return (Theme.inkFaint, Theme.ink)
        }
    }

    private func placeLabels(_ markers: inout [Marker], in context: GraphicsContext, size: CGSize) {
        var occupied: [CGRect] = []
        let order = markers.indices.sorted { markers[$0].point.y < markers[$1].point.y }

        for index in order {
            let marker = markers[index]
            let labelSize = measuredLabel(for: marker, in: context)
            var rightAligned = false
            var rect: CGRect

            if !marker.track.hasBearing {
                rect = CGRect(
                    x: marker.point.x - labelSize.width / 2,
                    y: marker.point.y - labelSize.height - 6,
                    width: labelSize.width,
                    height: labelSize.height
                )
            } else if marker.point.x > size.width - 40 {
                rightAligned = true
                rect = CGRect(
                    x: marker.point.x - 20 - labelSize.width,
                    y: marker.point.y - labelSize.height / 2,
                    width: labelSize.width,
                    height: labelSize.height
                )
            } else {
                rect = CGRect(
                    x: marker.point.x + 20,
                    y: marker.point.y - labelSize.height / 2,
                    width: labelSize.width,
                    height: labelSize.height
                )
            }

            if occupied.contains(where: { $0.intersects(rect) }) {
                rightAligned = false
                rect.origin = CGPoint(x: marker.point.x - 8, y: marker.point.y + 12)
                while occupied.contains(where: { $0.intersects(rect) }) {
                    rect.origin.y += labelSize.height
                }
            }
            markers[index].labelRect = rect
            markers[index].labelRightAligned = rightAligned
            occupied.append(rect)
        }
    }

    private func measuredLabel(for marker: Marker, in context: GraphicsContext) -> CGSize {
        let name = context.resolve(nameText(for: marker))
        let distance = context.resolve(distanceText(for: marker))
        let bound = CGSize(width: 220, height: 32)
        let nameSize = name.measure(in: bound)
        let distanceSize = distance.measure(in: bound)
        return CGSize(width: max(nameSize.width, distanceSize.width), height: nameSize.height + distanceSize.height + 1)
    }

    private func drawMarkers(
        _ markers: [Marker],
        in context: inout GraphicsContext,
        centre: CGPoint,
        pointsPerMetre: CGFloat
    ) {
        for marker in markers {
            if marker.track.hasBearing {
                let path = arrowPath(
                    width: 16,
                    height: 20,
                    centre: marker.point,
                    rotation: marker.rotation
                )
                let color = marker.markerColor.opacity(marker.opacity)
                if case .inferred = marker.track.source, marker.hasFacing {
                    context.stroke(path, with: .color(color), lineWidth: 1.25)
                } else {
                    context.fill(path, with: .color(color))
                }
                if marker.isClamped {
                    drawEdgeChevron(for: marker, in: &context, centre: centre)
                }
            } else {
                let radius = CGFloat(marker.track.distance) * pointsPerMetre
                let ring = Path(ellipseIn: CGRect(
                    x: centre.x - radius,
                    y: centre.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
                context.stroke(
                    ring,
                    with: .color(Theme.inkFaint.opacity(marker.opacity)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 4])
                )
                let dot = Path(ellipseIn: CGRect(x: marker.point.x - 1.5, y: marker.point.y - 1.5, width: 3, height: 3))
                context.fill(dot, with: .color(Theme.inkFaint.opacity(marker.opacity)))
            }
        }

        for marker in markers.sorted(by: { $0.point.y < $1.point.y }) {
            drawLabel(for: marker, in: &context)
        }
    }

    private func drawLabel(for marker: Marker, in context: inout GraphicsContext) {
        let name = context.resolve(nameText(for: marker))
        let distance = context.resolve(distanceText(for: marker))
        let rect = marker.labelRect
        let anchor: UnitPoint = marker.labelRightAligned ? .topTrailing : .topLeading
        let x = marker.labelRightAligned ? rect.maxX : rect.minX
        context.draw(name, at: CGPoint(x: x, y: rect.minY), anchor: anchor)
        let nameHeight = name.measure(in: CGSize(width: 220, height: 32)).height
        context.draw(distance, at: CGPoint(x: x, y: rect.minY + nameHeight + 1), anchor: anchor)
    }

    private func nameText(for marker: Marker) -> Text {
        Text(marker.track.name.uppercased())
            .font(Theme.mono(11, .semibold))
            .kerning(Theme.tracking(11))
            .foregroundStyle(marker.labelColor.opacity(marker.opacity))
    }

    private func distanceText(for marker: Marker) -> Text {
        Text(distanceLabel(for: marker.track))
            .font(Theme.mono(10))
            .monospacedDigit()
            .foregroundStyle(Theme.inkDim.opacity(marker.opacity))
    }

    private func distanceLabel(for track: TacticalMapModel.Track) -> String {
        let feet = track.distance / 0.3048
        let value = feet < 100
            ? String(format: "%.1f FT", Double(feet))
            : String(format: "%.0f FT", Double(feet))
        switch track.source {
        case .aging, .inferred:
            return "~" + value
        case .relayed:
            return "!" + value
        case .live, .none:
            return value
        }
    }

    private func drawEdgeChevron(for marker: Marker, in context: inout GraphicsContext, centre: CGPoint) {
        var direction = CGVector(dx: marker.rawPoint.x - centre.x, dy: marker.rawPoint.y - centre.y)
        let length = max(hypot(direction.dx, direction.dy), 0.001)
        direction.dx /= length
        direction.dy /= length
        let tip = CGPoint(x: marker.point.x + direction.dx * 11, y: marker.point.y + direction.dy * 11)
        let base = CGPoint(x: tip.x - direction.dx * 4, y: tip.y - direction.dy * 4)
        let perpendicular = CGVector(dx: -direction.dy * 2, dy: direction.dx * 2)
        var chevron = Path()
        chevron.move(to: CGPoint(x: base.x + perpendicular.dx, y: base.y + perpendicular.dy))
        chevron.addLine(to: tip)
        chevron.addLine(to: CGPoint(x: base.x - perpendicular.dx, y: base.y - perpendicular.dy))
        context.stroke(chevron, with: .color(marker.markerColor.opacity(marker.opacity)), lineWidth: 1)
    }

    private func drawSelfMarker(in context: inout GraphicsContext, centre: CGPoint, time: TimeInterval) {
        let glowArrow = arrowPath(width: 22 * 1.6, height: 26 * 1.6, centre: centre, rotation: 0)
        context.fill(glowArrow, with: .color(Theme.ember.opacity(0.10)))
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 12))
            let circle = Path(ellipseIn: CGRect(x: centre.x - 15, y: centre.y - 15, width: 30, height: 30))
            layer.fill(circle, with: .color(Theme.ember.opacity(0.18)))
        }

        let phase = 2 * Double.pi * time / 3.0
        let radius = 26 + 6 * sin(phase)
        let ringOpacity = 0.10 + 0.08 * (0.5 + 0.5 * sin(phase))
        let ring = Path(ellipseIn: CGRect(
            x: centre.x - radius,
            y: centre.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.stroke(ring, with: .color(Theme.ember.opacity(ringOpacity)), lineWidth: 1)

        let arrow = arrowPath(width: 22, height: 26, centre: centre, rotation: 0)
        context.fill(arrow, with: .color(Theme.ember))
    }

    private func drawScaleBar(in context: inout GraphicsContext, size: CGSize, pointsPerMetre: CGFloat) {
        let length = CGFloat(gridFeet) * 0.3048 * pointsPerMetre
        let start = CGPoint(x: 16.5, y: size.height - 16.5)
        let end = CGPoint(x: start.x + length, y: start.y)
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        path.move(to: CGPoint(x: start.x, y: start.y - 2))
        path.addLine(to: CGPoint(x: start.x, y: start.y + 2))
        path.move(to: CGPoint(x: end.x, y: end.y - 2))
        path.addLine(to: CGPoint(x: end.x, y: end.y + 2))
        context.stroke(path, with: .color(Theme.inkDim), lineWidth: 1)

        let label = context.resolve(
            Text("\(gridFeet) FT")
                .font(Theme.mono(10))
                .kerning(Theme.tracking(10))
                .foregroundStyle(Theme.inkDim)
        )
        context.draw(label, at: CGPoint(x: start.x, y: start.y - 6), anchor: .bottomLeading)
    }

    private func drawCompass(in context: inout GraphicsContext, size: CGSize) {
        let centre = CGPoint(x: size.width - 29, y: 29)
        let circle = Path(ellipseIn: CGRect(x: centre.x - 13, y: centre.y - 13, width: 26, height: 26))
        context.stroke(circle, with: .color(Theme.line), lineWidth: 1)

        let rotation = -heading
        let needle = slimNeedlePath(centre: centre, rotation: rotation)
        context.fill(needle, with: .color(Theme.inkDim))

        let direction = CGVector(dx: CGFloat(sin(rotation)), dy: CGFloat(-cos(rotation)))
        let north = context.resolve(
            Text("N")
                .font(Theme.mono(8))
                .kerning(Theme.tracking(8))
                .foregroundStyle(Theme.inkFaint)
        )
        context.draw(
            north,
            at: CGPoint(x: centre.x + direction.dx * 19, y: centre.y + direction.dy * 19),
            anchor: .center
        )
    }

    private func drawEmptyState(in context: inout GraphicsContext, centre: CGPoint, time: TimeInterval) {
        let label = context.resolve(
            Text("SCANNING FOR TEAM")
                .font(Theme.mono(10))
                .kerning(Theme.tracking(10))
                .foregroundStyle(Theme.inkFaint)
        )
        context.draw(label, at: CGPoint(x: centre.x, y: centre.y + 44), anchor: .top)

        let start = Angle.radians((time.truncatingRemainder(dividingBy: 4) / 4) * 2 * .pi - .pi / 2)
        let end = Angle.radians(start.radians + .pi / 3)
        var arc = Path()
        arc.addArc(center: centre, radius: 60, startAngle: start, endAngle: end, clockwise: false)
        context.stroke(arc, with: .color(Theme.ember.opacity(0.35)), lineWidth: 1)
    }

    private func arrowPath(width: CGFloat, height: CGFloat, centre: CGPoint, rotation: Float) -> Path {
        let pivot = CGPoint(x: width * 0.5, y: height * 0.55)
        let cosine = CGFloat(cos(rotation))
        let sine = CGFloat(sin(rotation))
        let points = [
            CGPoint(x: width * 0.5, y: 0),
            CGPoint(x: width, y: height),
            CGPoint(x: width * 0.5, y: height * 0.74),
            CGPoint(x: 0, y: height)
        ].map { point -> CGPoint in
            let x = point.x - pivot.x
            let y = point.y - pivot.y
            return CGPoint(
                x: centre.x + x * cosine - y * sine,
                y: centre.y + x * sine + y * cosine
            )
        }
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private func slimNeedlePath(centre: CGPoint, rotation: Float) -> Path {
        let direction = CGVector(dx: CGFloat(sin(rotation)), dy: CGFloat(-cos(rotation)))
        let perpendicular = CGVector(dx: -direction.dy, dy: direction.dx)
        let tip = CGPoint(x: centre.x + direction.dx * 4.5, y: centre.y + direction.dy * 4.5)
        let base = CGPoint(x: centre.x - direction.dx * 4.5, y: centre.y - direction.dy * 4.5)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x + perpendicular.dx, y: base.y + perpendicular.dy))
        path.addLine(to: CGPoint(x: base.x - perpendicular.dx, y: base.y - perpendicular.dy))
        path.closeSubpath()
        return path
    }

    private var gridFeet: Int {
        let feet = model.halfWidthMeters / 0.3048
        let index = TacticalMapModel.ladderFeet.enumerated().min {
            abs($0.element - feet) < abs($1.element - feet)
        }?.offset ?? 2
        return [2, 4, 5, 10, 10, 20, 40][index]
    }

    private func snapped(_ value: CGFloat) -> CGFloat {
        floor(value) + 0.5
    }
}
