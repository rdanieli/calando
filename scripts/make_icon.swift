import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("uso: make_icon <saida.png>\n".utf8))
    exit(64)
}

let canvas: CGFloat = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    exit(70)
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red / 255, green / 255, blue / 255, alpha])!
}

let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
context.addPath(platePath)
context.setFillColor(color(30, 22, 80))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(platePath)
context.clip()
let background = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(124, 92, 255), color(72, 48, 190), color(26, 18, 74)] as CFArray,
    locations: [0, 0.45, 1]
)!
context.drawLinearGradient(
    background,
    start: CGPoint(x: plate.minX, y: plate.maxY),
    end: CGPoint(x: plate.maxX, y: plate.minY),
    options: []
)
let glow = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(255, 255, 255, 0.22), color(255, 255, 255, 0)] as CFArray,
    locations: [0, 1]
)!
context.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: 360, y: 900),
    startRadius: 0,
    endCenter: CGPoint(x: 360, y: 900),
    endRadius: 620,
    options: []
)
context.restoreGState()

struct FaderGlyph {
    let centerX: CGFloat
    let level: CGFloat
    let accent: CGColor
}

let glyphs = [
    FaderGlyph(centerX: 342, level: 0.74, accent: color(120, 235, 255)),
    FaderGlyph(centerX: 512, level: 0.34, accent: color(255, 255, 255)),
    FaderGlyph(centerX: 682, level: 0.58, accent: color(255, 184, 92)),
]

let trackBottom: CGFloat = 268
let trackHeight: CGFloat = 488
let trackWidth: CGFloat = 36
let knobSize = CGSize(width: 132, height: 72)

for glyph in glyphs {
    let track = CGRect(x: glyph.centerX - trackWidth / 2, y: trackBottom, width: trackWidth, height: trackHeight)
    context.addPath(CGPath(roundedRect: track, cornerWidth: trackWidth / 2, cornerHeight: trackWidth / 2, transform: nil))
    context.setFillColor(color(10, 6, 40, 0.42))
    context.fillPath()

    let knobCenterY = trackBottom + trackHeight * glyph.level
    let filled = CGRect(x: track.minX, y: trackBottom, width: trackWidth, height: knobCenterY - trackBottom)
    context.addPath(CGPath(roundedRect: filled, cornerWidth: trackWidth / 2, cornerHeight: trackWidth / 2, transform: nil))
    context.setFillColor(glyph.accent)
    context.fillPath()

    let knob = CGRect(
        x: glyph.centerX - knobSize.width / 2,
        y: knobCenterY - knobSize.height / 2,
        width: knobSize.width,
        height: knobSize.height
    )
    let knobPath = CGPath(roundedRect: knob, cornerWidth: 26, cornerHeight: 26, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(8, 4, 40, 0.55))
    context.addPath(knobPath)
    context.setFillColor(color(255, 255, 255))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(knobPath)
    context.clip()
    let sheen = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(255, 255, 255), color(222, 220, 240)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: knob.midX, y: knob.maxY),
        end: CGPoint(x: knob.midX, y: knob.minY),
        options: []
    )
    context.restoreGState()

    let grip = CGRect(x: knob.midX - 34, y: knob.midY - 4, width: 68, height: 8)
    context.addPath(CGPath(roundedRect: grip, cornerWidth: 4, cornerHeight: 4, transform: nil))
    context.setFillColor(color(72, 48, 190, 0.85))
    context.fillPath()
}

guard let image = context.makeImage() else { exit(70) }
let representation = NSBitmapImageRep(cgImage: image)
guard let png = representation.representation(using: .png, properties: [:]) else { exit(70) }
try png.write(to: URL(fileURLWithPath: arguments[1]))
