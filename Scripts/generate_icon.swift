import Foundation

// Copy the supplied artwork at its native sizes into a macOS iconset.
// Package with: iconutil -c icns <output.iconset> -o App/Resources/AppIcon.icns
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Assets/AppIcon.iconset", isDirectory: true)
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift Scripts/generate_icon.swift <output.iconset>\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let manager = FileManager.default
try manager.createDirectory(at: output, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(points)x\(points)\(suffix).png"
    let data = try Data(contentsOf: source.appendingPathComponent(name))
    try data.write(to: output.appendingPathComponent(name), options: .atomic)
}
