#!/usr/bin/env swift
// Generates the AppIcon.appiconset PNGs.
//
// Concept: two overlapping rounded rectangles — Mac (cooler, larger) behind,
// Android (warmer, slightly smaller) front-right. macOS-standard squircle
// corner (~22.4% radius). Soft gradient backdrop hints at "connection".
//
// Run:  swift scripts/generate-icon.swift
// Out:  App/Resources/Assets.xcassets/AppIcon.appiconset/

import AppKit
import CoreGraphics
import Foundation

let outDir = URL(fileURLWithPath: "App/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// macOS app icon sizes (point size × density). We render each PNG at its pixel size.
let pngs: [Int] = [16, 32, 64, 128, 256, 512, 1024]

func drawIcon(_ pixels: Int) -> Data? {
  let size = CGFloat(pixels)
  guard let ctx = CGContext(
    data: nil,
    width: pixels, height: pixels,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else { return nil }

  // 1. Squircle clip
  let r = size * 0.224
  let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                    cornerWidth: r, cornerHeight: r, transform: nil)
  ctx.addPath(path); ctx.clip()

  // 2. Background — diagonal gradient, deep indigo → magenta accent
  let colors = [
    CGColor(red: 0.36, green: 0.30, blue: 0.95, alpha: 1),  // indigo
    CGColor(red: 0.92, green: 0.31, blue: 0.62, alpha: 1),  // magenta
  ] as CFArray
  let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1])!
  ctx.drawLinearGradient(gradient,
                         start: CGPoint(x: 0, y: size),
                         end: CGPoint(x: size, y: 0),
                         options: [])

  // 3. Two overlapping rounded rectangles in white — Mac (back-left, wider)
  //    and Android (front-right, smaller). The negative space between forms
  //    a unifying notch suggestive of bridged ecosystems.
  let cornerRel: CGFloat = 0.13
  let stroke = max(size * 0.045, 1)   // crisp line at all sizes

  // Mac card (slightly larger, behind)
  let macW = size * 0.48
  let macH = size * 0.36
  let macRect = CGRect(x: size * 0.13, y: size * 0.36, width: macW, height: macH)
  let macRadius = size * cornerRel
  drawRoundedRect(ctx: ctx, rect: macRect, radius: macRadius,
                  fill: CGColor(gray: 1, alpha: 0.92), stroke: nil)

  // Android card (front-right, overlapping). Phone-shaped portrait.
  let phoneW = size * 0.32
  let phoneH = size * 0.50
  let phoneRect = CGRect(x: size * 0.45, y: size * 0.22, width: phoneW, height: phoneH)
  drawRoundedRect(ctx: ctx, rect: phoneRect, radius: size * cornerRel * 0.9,
                  fill: CGColor(red: 0.39, green: 0.86, blue: 0.45, alpha: 1.0),
                  stroke: (CGColor.white, stroke))

  // Android camera dot (only visible at 64+ to avoid noise)
  if pixels >= 64 {
    let dotR = max(size * 0.022, 1.5)
    let dotX = phoneRect.midX
    let dotY = phoneRect.maxY - size * 0.06
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
    ctx.fillEllipse(in: CGRect(x: dotX - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
  }

  guard let cg = ctx.makeImage() else { return nil }
  let rep = NSBitmapImageRep(cgImage: cg)
  return rep.representation(using: .png, properties: [:])
}

func drawRoundedRect(
  ctx: CGContext, rect: CGRect, radius: CGFloat,
  fill: CGColor, stroke: (CGColor, CGFloat)?
) {
  let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
  ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath()
  if let (color, width) = stroke {
    ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.strokePath()
  }
}

// Emit PNGs
for px in pngs {
  guard let data = drawIcon(px) else {
    print("ERROR rendering \(px)"); continue
  }
  let url = outDir.appendingPathComponent("icon_\(px).png")
  try data.write(to: url)
  print("wrote \(url.path) (\(data.count) bytes)")
}

// Emit Contents.json — maps point sizes × density to filenames.
let manifest: [String: Any] = [
  "images": [
    ["size": "16x16",     "idiom": "mac", "scale": "1x", "filename": "icon_16.png"],
    ["size": "16x16",     "idiom": "mac", "scale": "2x", "filename": "icon_32.png"],
    ["size": "32x32",     "idiom": "mac", "scale": "1x", "filename": "icon_32.png"],
    ["size": "32x32",     "idiom": "mac", "scale": "2x", "filename": "icon_64.png"],
    ["size": "128x128",   "idiom": "mac", "scale": "1x", "filename": "icon_128.png"],
    ["size": "128x128",   "idiom": "mac", "scale": "2x", "filename": "icon_256.png"],
    ["size": "256x256",   "idiom": "mac", "scale": "1x", "filename": "icon_256.png"],
    ["size": "256x256",   "idiom": "mac", "scale": "2x", "filename": "icon_512.png"],
    ["size": "512x512",   "idiom": "mac", "scale": "1x", "filename": "icon_512.png"],
    ["size": "512x512",   "idiom": "mac", "scale": "2x", "filename": "icon_1024.png"],
  ],
  "info": ["version": 1, "author": "xcode"],
]
let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote Contents.json")

// Root assets catalog manifest (only need to write once).
let rootURL = URL(fileURLWithPath: "App/Resources/Assets.xcassets/Contents.json")
if !FileManager.default.fileExists(atPath: rootURL.path) {
  let rootJSON = try JSONSerialization.data(
    withJSONObject: ["info": ["version": 1, "author": "xcode"]],
    options: [.prettyPrinted]
  )
  try rootJSON.write(to: rootURL)
}
print("done.")
