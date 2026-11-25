#!/usr/bin/env swift
//
// generate-app-icon.swift — vector icon generator for SwitchMTP Batch.
//
// Everything is drawn with Core Graphics from primitives: no bitmap source,
// no external editor, so the icon stays reproducible and tweakable in code.
//
// Outputs:
//   icon-1024.png                                   master, transparent bg
//   icon-preview.png                                light/dark mockup sheet
//   build/AppIcon.iconset/*.png                     iconutil-compatible set
//   build/AppIcon.icns                              compiled icon
//   app/Resources/Assets.xcassets/AppIcon.appiconset/*.png
//
// Design language: macOS 26 "Liquid Glass".
//   * 824 x 824 squircle on the 1024 grid — Apple's icon safe area,
//   * translucent slab + specular sheen + rim light instead of hard bevels,
//   * near-black substrate so the Switch neon stays premium,
//   * Switch silhouette in landscape: two Joy-Con pods flanking a glass tablet,
//   * glyph: batch stack + downward transfer arrow.
//
// Usage:
//   swift scripts/generate-app-icon.swift [--install] [--only-master]
//   swift scripts/generate-app-icon.swift --from build/icon-render/icon-2048.png
//
//   --from <png>   mount a liquid-composer render on the macOS 824/1024 grid
//                  instead of drawing the icon with Core Graphics
//   --install      also copy the compiled .icns into existing app bundles
//   --only-master  skip .iconset/.icns (fast design iteration)
//
// Both paths are kept: the Core Graphics renderer is the offline fallback that
// needs no browser, --from consumes the Liquid Glass render from
// scripts/build-app-icon.py.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

// MARK: - Color

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

enum Ink {
    static let substrateTop    = rgb(0.098, 0.118, 0.169)   // #191E2B
    static let substrateMid    = rgb(0.047, 0.059, 0.090)   // #0C0F17
    static let substrateBottom = rgb(0.016, 0.020, 0.031)   // #040508
    static let cyanGlow = rgb(0.18, 0.76, 1.00)
    static let redGlow  = rgb(1.00, 0.24, 0.31)
}

let S: CGFloat = 1024

// MARK: - Geometry

/// Continuous-curvature squircle (superellipse), the silhouette Apple uses
/// for app icon bodies. n ≈ 5 matches the macOS rounded square.
func squircle(_ rect: CGRect, n: CGFloat = 5.0) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 1440
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
           cornerWidth: r, cornerHeight: r, transform: nil)
}

func grad(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: stops.map { $0.0 } as CFArray,
               locations: stops.map { $0.1 })!
}

func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let ca = a.components ?? [0, 0, 0, 1]
    let cb = b.components ?? [0, 0, 0, 1]
    var out: [CGFloat] = []
    for i in 0..<4 { out.append(ca[i] + (cb[i] - ca[i]) * t) }
    return CGColor(srgbRed: out[0], green: out[1], blue: out[2],
                   alpha: min(1, out[3]))
}

extension CGContext {
    /// Vertical capsule — the Joy-Con pod.
    func capsule(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
        rr(x, y, w, h, w / 2)
    }

    func fillLinear(path: CGPath? = nil,
                    from: CGPoint, to: CGPoint,
                    stops: [(CGColor, CGFloat)],
                    blend: CGBlendMode = .normal) {
        saveGState()
        if let p = path { addPath(p); clip() }
        setBlendMode(blend)
        drawLinearGradient(grad(stops), start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        restoreGState()
    }

    /// Elliptical radial gradient — used for blooms, contact shadows and
    /// the soft specular pools.
    func fillRadial(path: CGPath? = nil, center: CGPoint,
                    radiusX: CGFloat, radiusY: CGFloat,
                    stops: [(CGColor, CGFloat)],
                    blend: CGBlendMode = .normal) {
        saveGState()
        if let p = path { addPath(p); clip() }
        translateBy(x: center.x, y: center.y)
        scaleBy(x: 1, y: radiusY / radiusX)
        setBlendMode(blend)
        drawRadialGradient(grad(stops), startCenter: .zero, startRadius: 0,
                           endCenter: .zero, endRadius: radiusX, options: [])
        restoreGState()
    }

    func fill(_ path: CGPath, _ color: CGColor, blend: CGBlendMode = .normal) {
        saveGState(); setBlendMode(blend); addPath(path)
        setFillColor(color); fillPath(); restoreGState()
    }

    func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat,
                blend: CGBlendMode = .normal) {
        saveGState(); setBlendMode(blend); addPath(path)
        setStrokeColor(color); setLineWidth(width); setLineJoin(.round)
        strokePath(); restoreGState()
    }

    /// Stroke painted with a gradient — how glass rims get their
    /// light-on-top / shade-on-bottom falloff.
    func strokeLinear(_ path: CGPath, from: CGPoint, to: CGPoint,
                      stops: [(CGColor, CGFloat)], width: CGFloat,
                      blend: CGBlendMode = .normal) {
        saveGState()
        setBlendMode(blend)
        setLineWidth(width)
        setLineJoin(.round)
        addPath(path)
        replacePathWithStrokedPath()
        clip()
        drawLinearGradient(grad(stops), start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        restoreGState()
    }
}

// MARK: - Layout (1024 grid, origin top-left)

enum Layout {
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)

    // Switch in landscape: tablet wider than tall, pods flanking it.
    static let tablet = CGRect(x: 268, y: 306, width: 488, height: 412)
    static let screen = CGRect(x: 282, y: 320, width: 460, height: 384)
    static let leftPod = CGRect(x: 146, y: 306, width: 122, height: 412)
    static let rightPod = CGRect(x: 756, y: 306, width: 122, height: 412)
}

func arrowPath(centerX cx: CGFloat, top: CGFloat, joint: CGFloat, tip: CGFloat,
               shaftHalf: CGFloat, headHalf: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx - shaftHalf, y: top))
    p.addArc(tangent1End: CGPoint(x: cx + shaftHalf, y: top),
             tangent2End: CGPoint(x: cx + shaftHalf, y: joint), radius: 8)
    p.addArc(tangent1End: CGPoint(x: cx + shaftHalf, y: joint),
             tangent2End: CGPoint(x: cx + headHalf, y: joint), radius: 9)
    p.addArc(tangent1End: CGPoint(x: cx + headHalf, y: joint),
             tangent2End: CGPoint(x: cx, y: tip), radius: 7)
    p.addArc(tangent1End: CGPoint(x: cx, y: tip),
             tangent2End: CGPoint(x: cx - headHalf, y: joint), radius: 7)
    p.addArc(tangent1End: CGPoint(x: cx - headHalf, y: joint),
             tangent2End: CGPoint(x: cx - shaftHalf, y: joint), radius: 9)
    p.addArc(tangent1End: CGPoint(x: cx - shaftHalf, y: joint),
             tangent2End: CGPoint(x: cx - shaftHalf, y: top), radius: 8)
    p.closeSubpath()
    return p
}

// MARK: - Layers

func drawIcon(in ctx: CGContext) {
    let body = squircle(Layout.body, n: 5.0)

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()

    // 1 — substrate: cool graphite, slowly darkening downward.
    ctx.fillLinear(from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924),
                   stops: [(Ink.substrateTop, 0.0),
                           (Ink.substrateMid, 0.52),
                           (Ink.substrateBottom, 1.0)])

    // 2 — ambient light carried in from both Joy-Con colors.
    ctx.fillRadial(center: CGPoint(x: 232, y: 208), radiusX: 470, radiusY: 400,
                   stops: [(rgb(0.18, 0.74, 1.0, 0.24), 0.0),
                           (rgb(0.18, 0.74, 1.0, 0.05), 0.55),
                           (rgb(0.18, 0.74, 1.0, 0.0), 1.0)],
                   blend: .plusLighter)
    ctx.fillRadial(center: CGPoint(x: 840, y: 832), radiusX: 460, radiusY: 420,
                   stops: [(rgb(1.0, 0.22, 0.29, 0.26), 0.0),
                           (rgb(1.0, 0.22, 0.29, 0.05), 0.55),
                           (rgb(1.0, 0.22, 0.29, 0.0), 1.0)],
                   blend: .plusLighter)
    // light pooling behind the device, as if the glass were backlit
    ctx.fillRadial(center: CGPoint(x: 512, y: 470), radiusX: 420, radiusY: 300,
                   stops: [(rgb(1, 1, 1, 0.05), 0.0), (rgb(1, 1, 1, 0.0), 1.0)],
                   blend: .plusLighter)

    // 3 — contact shadow under the device.
    ctx.fillRadial(center: CGPoint(x: 512, y: 734), radiusX: 380, radiusY: 52,
                   stops: [(rgb(0, 0, 0, 0.55), 0.0),
                           (rgb(0, 0, 0, 0.22), 0.55),
                           (rgb(0, 0, 0, 0.0), 1.0)])

    // 3b — colored light spilling onto the shelf below the console.
    ctx.fillRadial(center: CGPoint(x: 214, y: 762), radiusX: 240, radiusY: 96,
                   stops: [(rgb(1.0, 0.30, 0.36, 0.16), 0.0),
                           (rgb(1.0, 0.30, 0.36, 0.0), 1.0)],
                   blend: .plusLighter)
    ctx.fillRadial(center: CGPoint(x: 810, y: 762), radiusX: 240, radiusY: 96,
                   stops: [(rgb(0.18, 0.78, 1.0, 0.16), 0.0),
                           (rgb(0.18, 0.78, 1.0, 0.0), 1.0)],
                   blend: .plusLighter)
    ctx.fillRadial(center: CGPoint(x: 512, y: 748), radiusX: 300, radiusY: 70,
                   stops: [(rgb(0.75, 0.94, 1.0, 0.07), 0.0),
                           (rgb(0.75, 0.94, 1.0, 0.0), 1.0)],
                   blend: .plusLighter)

    // 4 — hardware.
    drawHardware(ctx)
    drawGlyph(ctx)

    // 5 — one light direction only: a soft sheen from the top-left.
    ctx.fillLinear(from: CGPoint(x: 176, y: 96), to: CGPoint(x: 820, y: 560),
                   stops: [(rgb(1, 1, 1, 0.055), 0.0),
                           (rgb(1, 1, 1, 0.010), 0.42),
                           (rgb(1, 1, 1, 0.0), 1.0)],
                   blend: .plusLighter)

    // 6 — thickness of the slab, read as a vignette rather than a bevel.
    ctx.fillRadial(center: CGPoint(x: 512, y: 938), radiusX: 640, radiusY: 220,
                   stops: [(rgb(0, 0, 0, 0.30), 0.0),
                           (rgb(0, 0, 0, 0.10), 0.55),
                           (rgb(0, 0, 0, 0.0), 1.0)])

    // 7 — rim: definition hairline, then light that only catches the
    //     top-left arc (as if lit from above and slightly behind).
    ctx.stroke(squircle(Layout.body.insetBy(dx: 0.8, dy: 0.8), n: 5.0),
               rgb(0, 0, 0, 0.34), width: 1.6)
    ctx.strokeLinear(squircle(Layout.body.insetBy(dx: 4.5, dy: 4.5), n: 5.0),
                     from: CGPoint(x: 150, y: 130), to: CGPoint(x: 900, y: 940),
                     stops: [(rgb(1, 1, 1, 0.50), 0.0),
                              (rgb(1, 1, 1, 0.10), 0.34),
                              (rgb(0.80, 0.95, 1, 0.06), 0.72),
                              (rgb(1, 1, 1, 0.16), 1.0)],
                     width: 2.6)

    ctx.restoreGState()
}

/// One Joy-Con pod. The edge that meets the console is straight (it sits
/// on the rail), the outer edge keeps the capsule curve.
func podZone(_ rect: CGRect, rounded: PodEdge) -> CGPath {
    let r = rect.width / 2
    let p = CGMutablePath()
    switch rounded {
    case .left:
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                 tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: r)
        p.closeSubpath()
    case .right:
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: r)
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                 tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        p.closeSubpath()
    }
    return p
}

enum PodEdge { case left, right }

func drawHardware(_ ctx: CGContext) {
    let device = rr(Layout.leftPod.minX, Layout.tablet.minY,
                    Layout.rightPod.maxX - Layout.leftPod.minX,
                    Layout.tablet.height, 62)

    // Lift the console off the glass with one soft contact shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 30,
                  color: rgb(0, 0, 0, 0.55))
    ctx.addPath(device)
    ctx.setFillColor(rgb(0.03, 0.038, 0.052))
    ctx.fillPath()
    ctx.restoreGState()

    // Console body: near-black glass so the shell reads separate from the tile.
    ctx.fillLinear(path: device,
                   from: CGPoint(x: 512, y: Layout.tablet.minY),
                   to: CGPoint(x: 512, y: Layout.tablet.maxY),
                   stops: [(rgb(0.042, 0.052, 0.070), 0.0),
                           (rgb(0.020, 0.025, 0.034), 0.55),
                           (rgb(0.012, 0.015, 0.021), 1.0)])
    ctx.fillLinear(path: device,
                   from: CGPoint(x: Layout.leftPod.minX, y: Layout.tablet.minY),
                   to: CGPoint(x: 780, y: Layout.tablet.maxY),
                   stops: [(rgb(1, 1, 1, 0.055), 0.0), (rgb(1, 1, 1, 0.0), 0.6)],
                   blend: .plusLighter)

    // Joy-Con zones.
    drawPodFill(ctx, rect: Layout.leftPod, edge: .left,
                top: rgb(1.00, 0.38, 0.43), bottom: rgb(0.68, 0.03, 0.12),
                glow: Ink.redGlow)
    drawPodFill(ctx, rect: Layout.rightPod, edge: .right,
                top: rgb(0.30, 0.86, 1.00), bottom: rgb(0.015, 0.26, 0.74),
                glow: Ink.cyanGlow)

    // Seams where the pods meet the console.
    drawSeam(ctx, x: Layout.leftPod.maxX)
    drawSeam(ctx, x: Layout.rightPod.minX)

    // Screen well.
    let screen = rr(Layout.screen.minX, Layout.screen.minY,
                    Layout.screen.width, Layout.screen.height, 20)
    ctx.fillLinear(path: screen,
                   from: CGPoint(x: 512, y: Layout.screen.minY),
                   to: CGPoint(x: 512, y: Layout.screen.maxY),
                   stops: [(rgb(0.058, 0.150, 0.238), 0.0),
                           (rgb(0.028, 0.070, 0.114), 0.40),
                           (rgb(0.014, 0.028, 0.044), 0.76),
                           (rgb(0.009, 0.016, 0.025), 1.0)])
    ctx.fillRadial(path: screen, center: CGPoint(x: 512, y: 706),
                   radiusX: 300, radiusY: 140,
                   stops: [(rgb(0.20, 0.80, 1.0, 0.26), 0.0),
                           (rgb(0.20, 0.80, 1.0, 0.0), 1.0)],
                   blend: .plusLighter)
    // recessed lip
    ctx.saveGState()
    ctx.addPath(screen); ctx.clip()
    ctx.strokeLinear(rr(Layout.screen.minX - 5, Layout.screen.minY - 5,
                        Layout.screen.width + 10, Layout.screen.height + 10, 24),
                     from: CGPoint(x: 512, y: Layout.screen.minY),
                     to: CGPoint(x: 512, y: Layout.screen.maxY),
                     stops: [(rgb(0, 0, 0, 0.45), 0.0),
                              (rgb(0, 0, 0, 0.0), 0.26),
                              (rgb(0, 0, 0, 0.28), 1.0)],
                     width: 12)
    ctx.restoreGState()
    // lit hairline along the screen edge
    ctx.strokeLinear(screen,
                     from: CGPoint(x: 512, y: Layout.screen.minY),
                     to: CGPoint(x: 512, y: Layout.screen.maxY),
                     stops: [(rgb(0.90, 0.98, 1, 0.50), 0.0),
                              (rgb(0.78, 0.93, 1, 0.16), 0.50),
                              (rgb(0.84, 0.96, 1, 0.26), 1.0)],
                     width: 1.8)

    // Body rim: light along the top-left arc, faint bounce at the bottom.
    ctx.strokeLinear(device,
                     from: CGPoint(x: 190, y: Layout.tablet.minY),
                     to: CGPoint(x: 830, y: Layout.tablet.maxY),
                     stops: [(rgb(1, 1, 1, 0.52), 0.0),
                              (rgb(1, 1, 1, 0.16), 0.32),
                              (rgb(0.80, 0.94, 1, 0.08), 0.68),
                              (rgb(1, 1, 1, 0.20), 1.0)],
                     width: 2.2)
}

func drawPodFill(_ ctx: CGContext, rect: CGRect, edge: PodEdge,
                 top: CGColor, bottom: CGColor, glow: CGColor) {
    let path = podZone(rect, rounded: edge)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: glow.copy(alpha: 0.20)!)
    ctx.addPath(path)
    ctx.setFillColor(top)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.fillLinear(path: path,
                   from: CGPoint(x: rect.midX, y: rect.minY),
                   to: CGPoint(x: rect.midX, y: rect.maxY),
                   stops: [(top, 0.0),
                           (mix(top, bottom, 0.55), 0.38),
                           (bottom, 1.0)])

    // Light hugging the outer flank.
    let outer = edge == .left ? rect.minX : rect.maxX
    ctx.fillLinear(path: path,
                   from: CGPoint(x: outer + (edge == .left ? 4 : -4), y: rect.minY),
                   to: CGPoint(x: outer + (edge == .left ? 46 : -46),
                               y: rect.minY + rect.height * 0.62),
                   stops: [(rgb(1, 1, 1, 0.15), 0.0),
                           (rgb(1, 1, 1, 0.04), 0.45),
                           (rgb(1, 1, 1, 0.0), 1.0)],
                   blend: .plusLighter)

    // Rim of the pod itself.
    ctx.strokeLinear(path,
                     from: CGPoint(x: rect.midX, y: rect.minY),
                     to: CGPoint(x: rect.midX, y: rect.maxY),
                     stops: [(rgb(1, 1, 1, 0.44), 0.0),
                              (rgb(1, 1, 1, 0.10), 0.46),
                              (rgb(1, 1, 1, 0.06), 0.74),
                              (rgb(1, 1, 1, 0.22), 1.0)],
                     width: 2.0)

    // Analog stick, implied with a ring only.
    let dot = CGPath(ellipseIn: CGRect(x: rect.midX - 14, y: rect.minY + 40,
                                       width: 28, height: 28), transform: nil)
    ctx.fill(dot, rgb(0, 0, 0, 0.10))
    ctx.stroke(dot, rgb(1, 1, 1, 0.24), width: 1.4)
    ctx.fill(dot, rgb(1, 1, 1, 0.07), blend: .plusLighter)
}

/// Groove between pod and console: a shadowed line with a bright rail
/// on its lit side.
func drawSeam(_ ctx: CGContext, x: CGFloat) {
    let y0 = Layout.tablet.minY, y1 = Layout.tablet.maxY
    ctx.fillLinear(path: rr(x - 2, y0, 4, y1 - y0, 2),
                   from: CGPoint(x: x - 2, y: y0), to: CGPoint(x: x + 2, y: y0),
                   stops: [(rgb(0, 0, 0, 0.60), 0.0), (rgb(0, 0, 0, 0.10), 0.55),
                           (rgb(0, 0, 0, 0.0), 1.0)])
    ctx.fillLinear(path: rr(x + 1.2, y0 + 8, 1.6, y1 - y0 - 16, 0.8),
                   from: CGPoint(x: x + 2, y: y0), to: CGPoint(x: x + 2, y: y1),
                   stops: [(rgb(1, 1, 1, 0.20), 0.0), (rgb(1, 1, 1, 0.10), 0.5),
                           (rgb(1, 1, 1, 0.16), 1.0)],
                   blend: .plusLighter)
}

func drawGlyph(_ ctx: CGContext) {
    let cx: CGFloat = 512

    // Batch: three bars thinning upward, the front one at full strength.
    let bars: [(CGFloat, CGFloat, CGFloat)] = [
        (84, 372, 0.20), (114, 394, 0.33), (144, 416, 0.50),
    ]
    for (w, y, a) in bars {
        let h: CGFloat = 7
        let p = rr(cx - w / 2, y, w, h, h / 2)
        ctx.fillLinear(path: p,
                       from: CGPoint(x: cx - w / 2, y: y),
                       to: CGPoint(x: cx + w / 2, y: y),
                       stops: [(rgb(0.78, 0.93, 1.0, a), 0.0),
                                (rgb(1, 1, 1, a), 0.5),
                                (rgb(0.78, 0.93, 1.0, a), 1.0)],
                       blend: .plusLighter)
    }

    // Transfer arrow: white glass, cyan aura.
    let arrow = arrowPath(centerX: cx, top: 446, joint: 568, tip: 644,
                          shaftHalf: 21, headHalf: 54)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 26,
                  color: rgb(0.36, 0.86, 1.0, 0.50))
    ctx.addPath(arrow)
    ctx.setFillColor(rgb(1, 1, 1, 0.97))
    ctx.fillPath()
    ctx.restoreGState()

    // Cool light gathering toward the tip, plus a fine inner bevel.
    ctx.fillLinear(path: arrow,
                   from: CGPoint(x: cx, y: 452), to: CGPoint(x: cx, y: 646),
                   stops: [(rgb(1, 1, 1, 0.04), 0.0),
                           (rgb(0.90, 0.98, 1.0, 0.0), 0.55),
                           (rgb(0.66, 0.90, 1.0, 0.12), 1.0)],
                   blend: .plusLighter)
    ctx.strokeLinear(arrow,
                     from: CGPoint(x: cx, y: 452), to: CGPoint(x: cx, y: 646),
                     stops: [(rgb(1, 1, 1, 0.40), 0.0),
                              (rgb(0.84, 0.96, 1, 0.26), 1.0)],
                     width: 1.4)
}

// MARK: - Rendering

func renderIcon(pixels: Int, supersample: Int = 3) -> CGImage {
    let big = pixels * supersample
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: big, height: big, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let scale = CGFloat(big) / S
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: S)   // draw in top-left coordinates
    ctx.scaleBy(x: 1, y: -1)

    drawIcon(in: ctx)
    let master = ctx.makeImage()!

    if supersample == 1 { return master }
    let out = CGContext(data: nil, width: pixels, height: pixels,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    out.interpolationQuality = .high
    out.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return out.makeImage()!
}

func downscale(_ image: CGImage, to size: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

/// Draws a bitmap upright inside a context whose CTM is already flipped.
func drawUpright(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
}

func writePNG(_ image: CGImage, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString,
                                                     1, nil) else {
        FileHandle.standardError.write("cannot write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Preview sheet

func renderPreview(icon master: CGImage, size: CGSize) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let w = Int(size.width), h = Int(size.height)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high

    // Dark desktop (left) and light desktop (right).
    ctx.fillLinear(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: size.height),
                   stops: [(rgb(0.085, 0.09, 0.105), 0.0), (rgb(0.045, 0.048, 0.05), 1.0)])
    ctx.saveGState()
    ctx.clip(to: CGRect(x: size.width / 2, y: 0,
                        width: size.width / 2, height: size.height))
    ctx.fillLinear(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: size.height),
                   stops: [(rgb(0.965, 0.968, 0.975), 0.0), (rgb(0.885, 0.895, 0.910), 1.0)])
    ctx.restoreGState()

    // Large presentation.
    let big: CGFloat = 420
    for x in [size.width * 0.25, size.width * 0.75] {
        drawUpright(ctx, master, in: CGRect(x: x - big / 2, y: 96, width: big, height: big))
    }

    // Size ladder.
    var cursor: CGFloat = 132
    for s in [CGFloat(200), 128, 64, 32, 16] {
        let img = downscale(master, to: Int(s * 2))
        drawUpright(ctx, img, in: CGRect(x: cursor, y: 596, width: s, height: s))
        cursor += s + 58
    }

    return ctx.makeImage()!
}

/// macOS app icons live inside an 824 pt squircle on a 1024 pt canvas.
/// The renderer draws edge to edge (iOS style), so the glass render is
/// mounted at 824/1024 and left with a transparent margin.
func mountOnMacGrid(_ render: CGImage) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let body: CGFloat = 824
    ctx.draw(render, in: CGRect(x: (S - body) / 2, y: (S - body) / 2,
                                width: body, height: body))
    return ctx.makeImage()!
}

func loadPNG(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// MARK: - Main

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let buildDir = root.appendingPathComponent("build")
let projectRoot = root.deletingLastPathComponent()
let iconsetDir = buildDir.appendingPathComponent("AppIcon.iconset")
let assetDir = root.appendingPathComponent("app/Resources/Assets.xcassets/AppIcon.appiconset")

let args = Array(CommandLine.arguments.dropFirst())
let install = args.contains("--install")
let onlyMaster = args.contains("--only-master")

print("==> building master")
var sourceArg: String? = nil
if let i = args.firstIndex(of: "--from"), i + 1 < args.count { sourceArg = args[i + 1] }

let master: CGImage
if let path = sourceArg {
    guard let render = loadPNG(URL(fileURLWithPath: path)) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    master = mountOnMacGrid(render)
    print("    mounted \(path) at 824/1024")
} else {
    master = renderIcon(pixels: 1024, supersample: 3)
}
writePNG(master, projectRoot.appendingPathComponent("icon-1024.png"))
writePNG(master, buildDir.appendingPathComponent("icon-1024.png"))
writePNG(renderPreview(icon: master, size: CGSize(width: 1600, height: 900)),
         projectRoot.appendingPathComponent("icon-preview.png"))

if !onlyMaster {
    print("==> writing iconset")
    try? fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: assetDir, withIntermediateDirectories: true)

    let variants: [(Int, String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    for (px, name) in variants {
        let img = px == 1024 ? master : downscale(master, to: px)
        writePNG(img, iconsetDir.appendingPathComponent(name))
        writePNG(img, assetDir.appendingPathComponent(name))
    }

    print("==> compiling AppIcon.icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconsetDir.path,
                          "-o", buildDir.appendingPathComponent("AppIcon.icns").path]
    try? iconutil.run()
    iconutil.waitUntilExit()

    if install {
        let targets = [
            root.appendingPathComponent("build/products/SwitchMTP Batch.app/Contents/Resources/AppIcon.icns"),
            projectRoot.appendingPathComponent("SwitchMTP Batch.app/Contents/Resources/AppIcon.icns"),
        ]
        let icns = buildDir.appendingPathComponent("AppIcon.icns")
        for t in targets where fm.fileExists(atPath: t.deletingLastPathComponent().path) {
            if fm.fileExists(atPath: t.path) { try? fm.removeItem(at: t) }
            try? fm.copyItem(at: icns, to: t)
            print("    installed -> \(t.path)")
        }

        // CFBundleIconName points at AppIcon, so macOS resolves the icon from
        // Assets.car first; recompile it from the asset catalog we just wrote,
        // otherwise the bundle keeps showing the old artwork.
        print("==> recompiling Assets.car")
        let assets = root.appendingPathComponent("app/Resources/Assets.xcassets")
        let outDir = buildDir.appendingPathComponent("AppIcon.assets")
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let actool = Process()
        actool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        actool.arguments = ["actool", assets.path,
                            "--compile", outDir.path,
                            "--platform", "macosx",
                            "--minimum-deployment-target", "11.0",
                            "--app-icon", "AppIcon",
                            "--output-partial-info-plist", outDir.appendingPathComponent("partial.plist").path]
        actool.standardOutput = FileHandle.nullDevice
        actool.standardError = FileHandle.nullDevice
        do {
            try actool.run()
            actool.waitUntilExit()
        } catch {
            print("    actool unavailable, skipped")
        }
        let car = outDir.appendingPathComponent("Assets.car")
        if actool.terminationStatus == 0, fm.fileExists(atPath: car.path) {
            for bundle in ["build/products/SwitchMTP Batch.app", "SwitchMTP Batch.app"] {
                let doc = bundle.hasPrefix("build") ? root.appendingPathComponent(bundle)
                                                    : projectRoot.appendingPathComponent(bundle)
                let dst = doc.appendingPathComponent("Contents/Resources/Assets.car")
                guard fm.fileExists(atPath: dst.deletingLastPathComponent().path) else { continue }
                if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                try? fm.copyItem(at: car, to: dst)
                print("    Assets.car -> \(dst.path)")
            }
        } else {
            print("    actool failed, Assets.car left untouched")
        }
    }
}

print("done.")
