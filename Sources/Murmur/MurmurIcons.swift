import SwiftUI

// MARK: - Minimal SVG path-data parser
//
// Renders the exact Phosphor Icons path data from the design mockup as
// SwiftUI Shapes, rather than substituting SF Symbols — a deliberate
// fidelity choice over the native-icon shortcut. Supports the SVG path
// commands these icons actually use: M/L/H/V/C/A/Z, upper (absolute) and
// lower (relative) case. Coordinates are in the icons' native 256×256
// viewBox.

enum SVGPathParser {
    static func parse(_ d: String) -> Path {
        var path = Path()
        let chars = Array(d)
        var i = 0
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        func skipSeparators() {
            while i < chars.count, chars[i] == "," || chars[i] == " "
                || chars[i] == "\n" || chars[i] == "\t" {
                i += 1
            }
        }

        func readNumber() -> Double? {
            skipSeparators()
            guard i < chars.count else { return nil }
            var s = ""
            if chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            var sawDot = false
            var sawDigit = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber {
                    s.append(c); i += 1; sawDigit = true
                } else if c == "." && !sawDot {
                    s.append(c); i += 1; sawDot = true
                } else {
                    break
                }
            }
            // Scientific notation, e.g. "1e-5" — not seen in these icons,
            // but harmless to accept.
            if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                s.append(chars[i]); i += 1
                if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
                while i < chars.count, chars[i].isNumber { s.append(chars[i]); i += 1 }
            }
            guard sawDigit else { return nil }
            return Double(s)
        }

        func readPoint() -> (x: Double, y: Double)? {
            guard let x = readNumber(), let y = readNumber() else { return nil }
            return (x, y)
        }

        func readFlag() -> Bool? {
            skipSeparators()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            let v = chars[i] == "1"
            i += 1
            return v
        }

        // Converts an SVG elliptical-arc segment (endpoint parameterization)
        // to one or more cubic Beziers, appended directly to `path`.
        // Standard construction per the SVG 1.1 spec, §F.6.
        func addArc(
            to end: CGPoint, rx: Double, ry: Double, xRotDeg: Double,
            largeArc: Bool, sweep: Bool, from start: CGPoint) {
            if rx == 0 || ry == 0 { path.addLine(to: end); return }
            var rx = abs(rx), ry = abs(ry)
            let phi = xRotDeg * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)

            let dx2 = (start.x - end.x) / 2, dy2 = (start.y - end.y) / 2
            let x1p = cosPhi * dx2 + sinPhi * dy2
            let y1p = -sinPhi * dx2 + cosPhi * dy2

            let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
            if lambda > 1 {
                let scale = lambda.squareRoot()
                rx *= scale; ry *= scale
            }

            let sign: Double = (largeArc != sweep) ? 1 : -1
            let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
            let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
            let coef = den == 0 ? 0 : sign * (max(0, num / den)).squareRoot()
            let cxp = coef * (rx * y1p) / ry
            let cyp = coef * -(ry * x1p) / rx

            let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
            let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

            func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
                let dot = ux * vx + uy * vy
                let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
                var a = acos(min(1, max(-1, dot / len)))
                if ux * vy - uy * vx < 0 { a = -a }
                return a
            }
            let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
            var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
            if !sweep, dTheta > 0 { dTheta -= 2 * .pi }
            if sweep, dTheta < 0 { dTheta += 2 * .pi }

            // Split into ≤90° segments for a good Bezier approximation.
            let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
            let delta = dTheta / Double(segments)
            let t = 4.0 / 3.0 * tan(delta / 4)

            var theta = theta1
            for _ in 0..<segments {
                let thetaEnd = theta + delta
                func pointOnEllipse(_ ang: Double) -> (p: CGPoint, dx: Double, dy: Double) {
                    let ex = cosPhi * rx * cos(ang) - sinPhi * ry * sin(ang) + cx
                    let ey = sinPhi * rx * cos(ang) + cosPhi * ry * sin(ang) + cy
                    let ddx = -cosPhi * rx * sin(ang) - sinPhi * ry * cos(ang)
                    let ddy = -sinPhi * rx * sin(ang) + cosPhi * ry * cos(ang)
                    return (CGPoint(x: ex, y: ey), ddx, ddy)
                }
                let p0 = pointOnEllipse(theta)
                let p1 = pointOnEllipse(thetaEnd)
                let c1 = CGPoint(x: p0.p.x + t * p0.dx, y: p0.p.y + t * p0.dy)
                let c2 = CGPoint(x: p1.p.x - t * p1.dx, y: p1.p.y - t * p1.dy)
                path.addCurve(to: p1.p, control1: c1, control2: c2)
                theta = thetaEnd
            }
        }

        // Tracks the second control point of the most recent `C`/`c`/`S`/`s`
        // curve, and whether the immediately preceding command was one of
        // those four — `S`/`s`'s own first control point is the reflection
        // of that point (or, if the preceding command wasn't a cubic curve
        // at all, coincides with the current point instead). Per the SVG
        // spec's own "smooth curveto" rule, §8.3.6.
        var lastControl2 = CGPoint.zero
        var lastWasCubicCurve = false

        while i < chars.count {
            skipSeparators()
            guard i < chars.count else { break }
            let cmd = chars[i]
            // `S`/`s` (smooth cubic Bézier) was missing here entirely —
            // Phosphor's own "question" icon (`.help`) is built from one,
            // and every `S`/`s` in it was silently skipped character by
            // character, leaving the question mark's curl rendering as a
            // dropped, collapsed fragment instead of a curve.
            guard "MmLlHhVvCcSsAaZz".contains(cmd) else { i += 1; continue }
            i += 1
            let isCubicCommand = cmd == "C" || cmd == "c" || cmd == "S" || cmd == "s"

            switch cmd {
            case "M", "m":
                guard let p = readPoint() else { continue }
                current = cmd == "m" ? CGPoint(x: current.x + p.x, y: current.y + p.y)
                                     : CGPoint(x: p.x, y: p.y)
                path.move(to: current)
                subpathStart = current
                // Subsequent coordinate pairs after an (im)plicit M are
                // treated as lineto, per the SVG spec. `i` is saved/restored
                // through the same closure capture readNumber() already
                // uses — mixing that with a separate `inout` parameter
                // over the same variable trips Swift's exclusivity checks.
                while true {
                    let save = i
                    guard let p2 = readPoint() else { i = save; break }
                    current = cmd == "m" ? CGPoint(x: current.x + p2.x, y: current.y + p2.y)
                                         : CGPoint(x: p2.x, y: p2.y)
                    path.addLine(to: current)
                }
            case "L", "l":
                while let p = readPoint() {
                    current = cmd == "l" ? CGPoint(x: current.x + p.x, y: current.y + p.y)
                                         : CGPoint(x: p.x, y: p.y)
                    path.addLine(to: current)
                }
            case "H", "h":
                while let x = readNumber() {
                    current = cmd == "h" ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
                    path.addLine(to: current)
                }
            case "V", "v":
                while let y = readNumber() {
                    current = cmd == "v" ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
                    path.addLine(to: current)
                }
            case "C", "c":
                while true {
                    guard let c1 = readPoint(), let c2 = readPoint(), let end = readPoint() else { break }
                    let control1 = cmd == "c" ? CGPoint(x: current.x + c1.x, y: current.y + c1.y) : CGPoint(x: c1.x, y: c1.y)
                    let control2 = cmd == "c" ? CGPoint(x: current.x + c2.x, y: current.y + c2.y) : CGPoint(x: c2.x, y: c2.y)
                    let endPoint = cmd == "c" ? CGPoint(x: current.x + end.x, y: current.y + end.y) : CGPoint(x: end.x, y: end.y)
                    path.addCurve(to: endPoint, control1: control1, control2: control2)
                    current = endPoint
                    lastControl2 = control2
                }
            case "S", "s":
                while true {
                    guard let c2 = readPoint(), let end = readPoint() else { break }
                    let control2 = cmd == "s" ? CGPoint(x: current.x + c2.x, y: current.y + c2.y) : CGPoint(x: c2.x, y: c2.y)
                    let endPoint = cmd == "s" ? CGPoint(x: current.x + end.x, y: current.y + end.y) : CGPoint(x: end.x, y: end.y)
                    let control1 = lastWasCubicCurve
                        ? CGPoint(x: 2 * current.x - lastControl2.x, y: 2 * current.y - lastControl2.y)
                        : current
                    path.addCurve(to: endPoint, control1: control1, control2: control2)
                    current = endPoint
                    lastControl2 = control2
                    // Set inline, not left to the trailing assignment
                    // after this `switch` — a *second* chained segment
                    // under this same `S`/`s` letter (implicit repeats,
                    // same as `C`/`c` above) needs this to already read
                    // `true` before that line is ever reached.
                    lastWasCubicCurve = true
                }
            case "A", "a":
                while true {
                    guard let rx = readNumber(), let ry = readNumber(), let rot = readNumber(),
                          let large = readFlag(), let sweep = readFlag(), let end = readPoint()
                    else { break }
                    let endPoint = cmd == "a" ? CGPoint(x: current.x + end.x, y: current.y + end.y) : CGPoint(x: end.x, y: end.y)
                    addArc(to: endPoint, rx: rx, ry: ry, xRotDeg: rot,
                           largeArc: large, sweep: sweep, from: current)
                    current = endPoint
                }
            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
            default:
                break
            }
            // Reset unless this command (or the one that just ran) was a
            // cubic curve — anything else in between means a later S/s
            // reflects nothing and starts from the current point instead.
            lastWasCubicCurve = isCubicCommand
        }
        return path
    }
}

// MARK: - Primitive shapes (SVG line/circle/polyline/polygon/rect)

enum SVGPrimitive {
    case path(String)
    case line(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat)
    case circle(cx: CGFloat, cy: CGFloat, r: CGFloat, filled: Bool = false)
    case polyline([CGPoint])
    case polygon([CGPoint])
    case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rx: CGFloat = 0)

    func path() -> Path {
        switch self {
        case .path(let d):
            return SVGPathParser.parse(d)
        case .line(let x1, let y1, let x2, let y2):
            var p = Path()
            p.move(to: CGPoint(x: x1, y: y1))
            p.addLine(to: CGPoint(x: x2, y: y2))
            return p
        case .circle(let cx, let cy, let r, _):
            return Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        case .polyline(let points):
            var p = Path()
            guard let first = points.first else { return p }
            p.move(to: first)
            for pt in points.dropFirst() { p.addLine(to: pt) }
            return p
        case .polygon(let points):
            var p = Path()
            guard let first = points.first else { return p }
            p.move(to: first)
            for pt in points.dropFirst() { p.addLine(to: pt) }
            p.closeSubpath()
            return p
        case .rect(let x, let y, let width, let height, let rx):
            return Path(roundedRect: CGRect(x: x, y: y, width: width, height: height),
                        cornerRadius: rx)
        }
    }

    var isFilled: Bool {
        if case .circle(_, _, _, let filled) = self { return filled }
        return false
    }
}

func pts(_ values: CGFloat...) -> [CGPoint] {
    stride(from: 0, to: values.count, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
}

// MARK: - Icon set
//
// Phosphor Icons (regular weight, 256×256 viewBox, 16pt stroke — see
// `MurmurIconView` below, which scales that stroke proportionally rather
// than substituting SF Symbols), MIT-licensed and reproduced on the Legal
// page like every other open-source component this app ships. Not
// imported as a package — Phosphor ships as SVG/font/framework bundles
// with no Swift target, so each icon's path/circle/line/polyline data is
// copied in as `SVGPrimitive`s instead, verified case-by-case against
// https://github.com/phosphor-icons/core's own `raw/regular/*.svg`
// source rather than hand-approximated. A couple (`.snip`, `.style`)
// don't match any single stock Phosphor icon exactly — both read as
// reasonable small compositions of Phosphor's own primitives (a link
// icon plus a cut mark; a horizontal fader track with circular knobs)
// rather than a transcription drift, so they're left as they are.

enum MurmurIcon {
    case home, ask, insights, scratch, dict, profile, snip, style, tpl, trans
    case settings, help, search, trash, copy, edit, plus, check, refresh
    case lines, wave, calendar, arrowRight, caret, bell, mic, fingerprint
    case wrench, lock, apps, sidebar, more, moreVertical, notetaker, clock
    case key

    var elements: [SVGPrimitive] {
        switch self {
        case .home:
            return [.path("M104,216V152h48v64h64V120a8,8,0,0,0-2.34-5.66l-80-80a8,8,0,0,0-11.32,0l-80,80A8,8,0,0,0,40,120v96Z")]
        case .ask:
            return [
                .line(x1: 96, y1: 112, x2: 160, y2: 112),
                .line(x1: 96, y1: 144, x2: 160, y2: 144),
                .path("M79.93,211.11a96,96,0,1,0-35-35h0L32.42,213.46a8,8,0,0,0,10.12,10.12l37.39-12.47Z"),
            ]
        case .insights, .lines:
            return [
                .polyline(pts(48, 208, 48, 136, 96, 136)),
                .line(x1: 224, y1: 208, x2: 32, y2: 208),
                .polyline(pts(96, 208, 96, 88, 152, 88)),
                .polyline(pts(152, 208, 152, 40, 208, 40, 208, 208)),
            ]
        case .scratch:
            return [
                .polygon(pts(128, 160, 96, 160, 96, 128, 192, 32, 224, 64, 128, 160)),
                .line(x1: 168, y1: 56, x2: 200, y2: 88),
                .path("M216,128v80a8,8,0,0,1-8,8H48a8,8,0,0,1-8-8V48a8,8,0,0,1,8-8h80"),
            ]
        case .dict:
            return [
                .path("M128,88a32,32,0,0,1,32-32h72V200H160a32,32,0,0,0-32,32"),
                .path("M24,200H96a32,32,0,0,1,32,32V88A32,32,0,0,0,96,56H24Z"),
                .line(x1: 160, y1: 96, x2: 200, y2: 96),
                .line(x1: 160, y1: 128, x2: 200, y2: 128),
                .line(x1: 160, y1: 160, x2: 200, y2: 160),
            ]
        case .profile, .wave:
            return [
                .line(x1: 48, y1: 96, x2: 48, y2: 160),
                .line(x1: 88, y1: 32, x2: 88, y2: 224),
                .line(x1: 128, y1: 64, x2: 128, y2: 192),
                .line(x1: 168, y1: 96, x2: 168, y2: 160),
                .line(x1: 208, y1: 80, x2: 208, y2: 176),
            ]
        case .snip:
            return [
                .line(x1: 96, y1: 160, x2: 160, y2: 96),
                .path("M112,76.11l30.06-30a48,48,0,0,1,67.88,67.88L179.88,144"),
                .path("M76.11,112l-30,30.06a48,48,0,0,0,67.88,67.88L144,179.88"),
            ]
        case .style:
            return [
                .circle(cx: 104, cy: 80, r: 24),
                .circle(cx: 168, cy: 176, r: 24),
                .line(x1: 128, y1: 80, x2: 216, y2: 80),
                .line(x1: 40, y1: 80, x2: 80, y2: 80),
                .line(x1: 192, y1: 176, x2: 216, y2: 176),
                .line(x1: 40, y1: 176, x2: 144, y2: 176),
            ]
        case .tpl:
            return [
                .path("M200,224H56a8,8,0,0,1-8-8V40a8,8,0,0,1,8-8h96l56,56V216A8,8,0,0,1,200,224Z"),
                .polyline(pts(152, 32, 152, 88, 208, 88)),
                .line(x1: 96, y1: 136, x2: 160, y2: 136),
                .line(x1: 96, y1: 168, x2: 160, y2: 168),
            ]
        case .trans:
            return [.polygon(pts(160, 16, 144, 96, 208, 120, 96, 240, 112, 160, 48, 136, 160, 16))]
        case .settings:
            return [
                .circle(cx: 128, cy: 128, r: 40),
                .path("M41.43,178.09A99.14,99.14,0,0,1,31.36,153.8l16.78-21a81.59,81.59,0,0,1,0-9.64l-16.77-21a99.43,99.43,0,0,1,10.05-24.3l26.71-3a81,81,0,0,1,6.81-6.81l3-26.7A99.14,99.14,0,0,1,102.2,31.36l21,16.78a81.59,81.59,0,0,1,9.64,0l21-16.77a99.43,99.43,0,0,1,24.3,10.05l3,26.71a81,81,0,0,1,6.81,6.81l26.7,3a99.14,99.14,0,0,1,10.07,24.29l-16.78,21a81.59,81.59,0,0,1,0,9.64l16.77,21a99.43,99.43,0,0,1-10,24.3l-26.71,3a81,81,0,0,1-6.81,6.81l-3,26.7a99.14,99.14,0,0,1-24.29,10.07l-21-16.78a81.59,81.59,0,0,1-9.64,0l-21,16.77a99.43,99.43,0,0,1-24.3-10l-3-26.71a81,81,0,0,1-6.81-6.81Z"),
            ]
        case .help:
            return [
                .circle(cx: 128, cy: 128, r: 96),
                .path("M128,144v-8c17.67,0,32-12.54,32-28s-14.33-28-32-28S96,92.54,96,108v4"),
                .circle(cx: 128, cy: 180, r: 12, filled: true),
            ]
        case .search:
            return [
                .circle(cx: 112, cy: 112, r: 80),
                .line(x1: 168.57, y1: 168.57, x2: 224, y2: 224),
            ]
        case .trash:
            return [
                .line(x1: 216, y1: 56, x2: 40, y2: 56),
                .line(x1: 104, y1: 104, x2: 104, y2: 168),
                .line(x1: 152, y1: 104, x2: 152, y2: 168),
                .path("M200,56V208a8,8,0,0,1-8,8H64a8,8,0,0,1-8-8V56"),
                .path("M168,56V40a16,16,0,0,0-16-16H104A16,16,0,0,0,88,40V56"),
            ]
        case .copy:
            return [
                .polyline(pts(168, 168, 216, 168, 216, 40, 88, 40, 88, 88)),
                .rect(x: 40, y: 88, width: 128, height: 128),
            ]
        case .edit:
            return [
                .path("M92.69,216H48a8,8,0,0,1-8-8V163.31a8,8,0,0,1,2.34-5.65L165.66,34.34a8,8,0,0,1,11.31,0L221.66,79a8,8,0,0,1,0,11.31L98.34,213.66A8,8,0,0,1,92.69,216Z"),
                .line(x1: 136, y1: 64, x2: 192, y2: 120),
                .line(x1: 164, y1: 92, x2: 68, y2: 188),
                .line(x1: 95.49, y1: 215.49, x2: 40.51, y2: 160.51),
            ]
        case .plus:
            return [
                .line(x1: 40, y1: 128, x2: 216, y2: 128),
                .line(x1: 128, y1: 40, x2: 128, y2: 216),
            ]
        case .check:
            return [.polyline(pts(40, 144, 96, 200, 224, 72))]
        case .refresh:
            return [
                .polyline(pts(184, 104, 232, 104, 232, 56)),
                .path("M188.4,192a88,88,0,1,1,1.83-126.23L232,104"),
            ]
        case .calendar:
            return [
                .rect(x: 40, y: 40, width: 176, height: 176, rx: 8),
                .line(x1: 176, y1: 24, x2: 176, y2: 56),
                .line(x1: 80, y1: 24, x2: 80, y2: 56),
                .line(x1: 40, y1: 88, x2: 216, y2: 88),
            ]
        case .more:
            return [
                .circle(cx: 60, cy: 128, r: 12, filled: true),
                .circle(cx: 128, cy: 128, r: 12, filled: true),
                .circle(cx: 196, cy: 128, r: 12, filled: true),
            ]
        case .moreVertical:
            return [
                .circle(cx: 128, cy: 60, r: 12, filled: true),
                .circle(cx: 128, cy: 128, r: 12, filled: true),
                .circle(cx: 128, cy: 196, r: 12, filled: true),
            ]
        case .notetaker:
            // A plain record glyph — ring + solid center dot — rather than
            // reusing `.mic` (already means "dictation" everywhere else in
            // this rail) or `.wave` (already Voice Profile's icon).
            return [
                .circle(cx: 128, cy: 128, r: 88, filled: false),
                .circle(cx: 128, cy: 128, r: 40, filled: true),
            ]
        case .clock:
            return [
                .circle(cx: 128, cy: 128, r: 96, filled: false),
                .line(x1: 128, y1: 128, x2: 128, y2: 72),
                .line(x1: 128, y1: 128, x2: 172, y2: 152),
            ]
        case .sidebar:
            return [
                .rect(x: 32, y: 48, width: 192, height: 160, rx: 8),
                .line(x1: 88, y1: 48, x2: 88, y2: 208),
            ]
        case .arrowRight:
            return [
                .line(x1: 40, y1: 128, x2: 216, y2: 128),
                .polyline(pts(144, 56, 216, 128, 144, 200)),
            ]
        case .caret:
            return [.polyline(pts(96, 48, 176, 128, 96, 208))]
        case .bell:
            return [
                .path("M96,192a32,32,0,0,0,64,0"),
                .path("M56,104a72,72,0,0,1,144,0c0,35.82,8.3,64.6,14.9,76A8,8,0,0,1,208,192H48a8,8,0,0,1-6.88-12C47.71,168.6,56,139.81,56,104Z"),
            ]
        case .mic:
            return [
                .rect(x: 88, y: 24, width: 80, height: 144, rx: 40),
                .line(x1: 128, y1: 200, x2: 128, y2: 240),
                .path("M200,128a72,72,0,0,1-144,0"),
            ]
        case .fingerprint:
            return [
                .path("M50.69,184.92A127.52,127.52,0,0,0,64,128a63.85,63.85,0,0,1,24-50"),
                .path("M128,128a191.11,191.11,0,0,1-24,93"),
                .path("M96,128a32,32,0,0,1,64,0,223.12,223.12,0,0,1-21.28,95.41"),
                .path("M218.56,184A289.45,289.45,0,0,0,224,128a96,96,0,0,0-192,0,95.8,95.8,0,0,1-5.47,32"),
                .path("M92.81,160a158.92,158.92,0,0,1-18.12,47.84"),
                .path("M120,64.5a66,66,0,0,1,8-.49,64,64,0,0,1,64,64,259.86,259.86,0,0,1-2,32"),
                .path("M183.94,192q-2.28,8.88-5.18,17.5"),
            ]
        case .wrench:
            return [.path("M104,126.94a64,64,0,0,1,80-90.29L144,80l5.66,26.34L176,112l43.35-40a64,64,0,0,1-90.29,80L73,217A24,24,0,0,1,39,183Z")]
        case .lock:
            return [
                .rect(x: 40, y: 88, width: 176, height: 128, rx: 8),
                .path("M88,88V56a40,40,0,0,1,80,0V88"),
            ]
        case .key:
            // Phosphor "key" (MIT), like the rest of the set: a round bow top-right, the shaft and its two notches
            // down to the bottom-left, and the hole in the bow.
            return [
                .path("M93.17,122.83a72,72,0,1,1,40,40h0L120,176H96v24H72v24H40a8,8,0,0,1-8-8V187.31a8,8,0,0,1,2.34-5.65l58.83-58.83Z"),
                .circle(cx: 180, cy: 76, r: 12, filled: true),
            ]
        case .apps:
            return [
                .rect(x: 48, y: 48, width: 64, height: 64, rx: 8),
                .rect(x: 144, y: 48, width: 64, height: 64, rx: 8),
                .rect(x: 48, y: 144, width: 64, height: 64, rx: 8),
                .rect(x: 144, y: 144, width: 64, height: 64, rx: 8),
            ]
        }
    }
}

// MARK: - Rendering

/// Every `.path("…")` primitive re-parses its SVG path data (character by
/// character, via `SVGPathParser`) on every call — fine for a handful of
/// static icons, but `path(in:)` runs on every draw, and a scrolling list
/// with several icon buttons per row calls it constantly. Each icon's
/// combined, unscaled geometry is cached the first time it's built, in its
/// native 256-unit space; every later draw just applies a scale transform
/// to that cached `Path`, which is cheap, instead of re-parsing.
private enum MurmurIconGeometryCache {
    static var stroke: [MurmurIcon: Path] = [:]
    static var fill: [MurmurIcon: Path] = [:]
}

private struct MurmurIconStrokeShape: Shape {
    let icon: MurmurIcon
    func path(in rect: CGRect) -> Path {
        let base: Path
        if let cached = MurmurIconGeometryCache.stroke[icon] {
            base = cached
        } else {
            var combined = Path()
            for element in icon.elements where !element.isFilled {
                combined.addPath(element.path())
            }
            MurmurIconGeometryCache.stroke[icon] = combined
            base = combined
        }
        let scale = rect.width / 256
        return base.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

private struct MurmurIconFillShape: Shape {
    let icon: MurmurIcon
    func path(in rect: CGRect) -> Path {
        let base: Path
        if let cached = MurmurIconGeometryCache.fill[icon] {
            base = cached
        } else {
            var combined = Path()
            for element in icon.elements where element.isFilled {
                combined.addPath(element.path())
            }
            MurmurIconGeometryCache.fill[icon] = combined
            base = combined
        }
        let scale = rect.width / 256
        return base.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// Renders a `MurmurIcon` at any size — sizing is view-driven via
/// `.frame(width:height:)`, matching how `Image(systemName:)` is normally
/// used. Tint with `.foregroundStyle`, same as any other vector icon.
struct MurmurIconView: View {
    let icon: MurmurIcon
    /// Matches the mockup's `stroke-width="16"` on a 256pt viewBox.
    private let nativeStrokeWidth: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / 256
            ZStack {
                MurmurIconStrokeShape(icon: icon)
                    .stroke(style: StrokeStyle(
                        lineWidth: nativeStrokeWidth * scale,
                        lineCap: .round, lineJoin: .round))
                if icon.elements.contains(where: { $0.isFilled }) {
                    MurmurIconFillShape(icon: icon)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
