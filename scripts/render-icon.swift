import AppKit

// Render the app icon and launch mark from DSH's whale logo.
// usage: swift scripts/render-icon.swift \
//   payload/node_modules/@deepseek-ai/dsh-web-frontend/dist/favicon.svg <outdir>
// then copy Icon-1024.png into AppIcon.appiconset and LaunchMark@*.png into
// LaunchMark.imageset.
let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
guard let svg = NSImage(contentsOf: svgURL) else { fatalError("cannot load svg") }

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// The whale as a single-colour layer of `size` px, drawn inside `box`.
func whale(size: Int, box: CGRect, color: CGColor) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    svg.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func save(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

// App icon: white whale on a DeepSeek-blue gradient, opaque.
let n = 1024
let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [rgb(0x7A93FF), rgb(0x4D6BFE), rgb(0x3A55E0)] as CFArray,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: n), end: CGPoint(x: n, y: 0), options: [])
let side = CGFloat(n) * 0.64
let box = CGRect(x: (CGFloat(n) - side) / 2, y: (CGFloat(n) - side) / 2 - CGFloat(n) * 0.01,
                 width: side, height: side)
ctx.draw(whale(size: n, box: box, color: rgb(0xFFFFFF)), in: CGRect(x: 0, y: 0, width: n, height: n))
save(ctx.makeImage()!, "Icon-1024.png")

// Launch mark: blue whale on transparent, same proportions as the old mark.
for (scale, px) in [(1, 240), (2, 480), (3, 720)] {
    let s = CGFloat(px) * 0.66
    let b = CGRect(x: (CGFloat(px) - s) / 2, y: (CGFloat(px) - s) / 2, width: s, height: s)
    save(whale(size: px, box: b, color: rgb(0x4D6BFE)), "LaunchMark@\(scale)x.png")
}
print("ok")
