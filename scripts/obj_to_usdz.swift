// Converts a textured OBJ (+ MTL + textures in the same folder) to a USDZ that
// RealityKit can load. Run on macOS with the Xcode toolchain:
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     swift scripts/obj_to_usdz.swift <input.obj> <output.usdz>
// Source files are read only; nothing in data/ is modified.

import Foundation
import ModelIO

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write("usage: obj_to_usdz <input.obj> <output.usdz>\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])

let asset = MDLAsset(url: input)
asset.loadTextures()

let ext = output.pathExtension.lowercased()
guard MDLAsset.canExportFileExtension(ext) else {
    FileHandle.standardError.write("export of .\(ext) not supported (try usdc/usda, then usdZip)\n".data(using: .utf8)!)
    exit(1)
}
do {
    try asset.export(to: output)
    print("wrote \(output.path)")
} catch {
    FileHandle.standardError.write("export failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
