//
//  makeicon.swift — генерация иконки Mistral (вентилятор на сине-градиентном фоне).
//  Запуск: swiftc scripts/makeicon.swift -o /tmp/makeicon && /tmp/makeicon <выход.png>
//

import AppKit

let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// фон — сине-градиентный скруглённый квадрат
let colors = [
    NSColor(calibratedRed: 0.20, green: 0.52, blue: 1.00, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.85, alpha: 1).cgColor
]
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: colors as CFArray, locations: [0, 1])!
let rounded = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                     cornerWidth: 220, cornerHeight: 220, transform: nil)
ctx.addPath(rounded)
ctx.clip()
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(size)),
                       end: CGPoint(x: 0, y: 0), options: [])

let center = CGFloat(size) / 2

// лопасти — три смещённых эллипса
ctx.setFillColor(NSColor.white.cgColor)
for i in 0..<3 {
    ctx.saveGState()
    ctx.translateBy(x: center, y: center)
    ctx.rotate(by: CGFloat(i) * 120 * .pi / 180)
    let blade = CGPath(ellipseIn: CGRect(x: -85, y: 70, width: 170, height: 360), transform: nil)
    ctx.addPath(blade)
    ctx.fillPath()
    ctx.restoreGState()
}

// ступица
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillEllipse(in: CGRect(x: center - 72, y: center - 72, width: 144, height: 144))
ctx.setFillColor(NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.85, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: center - 40, y: center - 40, width: 80, height: 80))

img.unlockFocus()

// сохранение PNG
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("makeicon: не удалось сгенерировать PNG")
    exit(1)
}

let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("makeicon: \(out) готово")
