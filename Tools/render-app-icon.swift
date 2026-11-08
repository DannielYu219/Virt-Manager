import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}
func path(_ points: [CGPoint]) -> CGPath {
    let result = CGMutablePath()
    result.move(to: points[0])
    for point in points.dropFirst() { result.addLine(to: point) }
    result.closeSubpath()
    return result
}
func fill(_ points: [CGPoint], _ cgColor: CGColor) {
    bitmap.addPath(path(points))
    bitmap.setFillColor(cgColor)
    bitmap.fillPath()
}
func stroke(_ points: [CGPoint], _ cgColor: CGColor, width: CGFloat) {
    bitmap.addPath(path(points))
    bitmap.setStrokeColor(cgColor)
    bitmap.setLineWidth(width)
    bitmap.setLineJoin(.round)
    bitmap.strokePath()
}
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: CGFloat(size) - y) }

bitmap.setFillColor(color(0.105, 0.125, 0.15))
bitmap.fill(CGRect(x: 0, y: 0, width: size, height: size))

// A dimensional stack of three virtual machine layers around a luminous compute core.
let top = [p(512, 186), p(807, 338), p(512, 490), p(217, 338)]
let left = [p(217, 338), p(512, 490), p(512, 594), p(217, 440)]
let right = [p(512, 490), p(807, 338), p(807, 442), p(512, 594)]
fill(top, color(0.28, 0.77, 0.88))
fill(left, color(0.19, 0.34, 0.40))
fill(right, color(0.12, 0.23, 0.29))
stroke(top, color(0.67, 0.94, 0.97), width: 8)
stroke(left, color(0.37, 0.68, 0.72), width: 6)
stroke(right, color(0.31, 0.57, 0.63), width: 6)

let middleTop = [p(512, 383), p(734, 497), p(512, 612), p(290, 497)]
let middleLeft = [p(290, 497), p(512, 612), p(512, 700), p(290, 585)]
let middleRight = [p(512, 612), p(734, 497), p(734, 585), p(512, 700)]
fill(middleTop, color(0.54, 0.64, 0.67))
fill(middleLeft, color(0.27, 0.35, 0.38))
fill(middleRight, color(0.20, 0.27, 0.31))
stroke(middleTop, color(0.82, 0.88, 0.88), width: 6)
stroke(middleLeft, color(0.48, 0.60, 0.62), width: 5)
stroke(middleRight, color(0.40, 0.52, 0.56), width: 5)

let bottomTop = [p(512, 568), p(663, 646), p(512, 724), p(361, 646)]
let bottomLeft = [p(361, 646), p(512, 724), p(512, 790), p(361, 712)]
let bottomRight = [p(512, 724), p(663, 646), p(663, 712), p(512, 790)]
fill(bottomTop, color(0.91, 0.60, 0.31))
fill(bottomLeft, color(0.48, 0.32, 0.20))
fill(bottomRight, color(0.32, 0.23, 0.18))
stroke(bottomTop, color(1.0, 0.78, 0.48), width: 5)
stroke(bottomLeft, color(0.71, 0.48, 0.29), width: 4)
stroke(bottomRight, color(0.60, 0.39, 0.25), width: 4)

// A small bright terminal window anchors the top virtual layer.
let window = [p(440, 323), p(512, 360), p(512, 421), p(440, 384)]
fill(window, color(0.07, 0.20, 0.25))
stroke(window, color(0.77, 0.99, 1.0), width: 5)
stroke([p(457, 350), p(475, 359), p(459, 368)], color(0.45, 0.91, 0.96), width: 7)
stroke([p(482, 374), p(496, 381)], color(0.96, 0.74, 0.43), width: 6)

let image = bitmap.makeImage()!
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
precondition(CGImageDestinationFinalize(destination))
print(output.path)
