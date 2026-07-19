#!/usr/bin/env swift

import Foundation

private struct IconRepresentation {
    let type: String
    let filename: String
}

private enum IconBuildError: Error {
    case fileTooLarge
    case invalidFourCharacterCode(String)
}

private let representations = [
    IconRepresentation(type: "icp4", filename: "icon_16x16.png"),
    IconRepresentation(type: "ic11", filename: "icon_16x16@2x.png"),
    IconRepresentation(type: "icp5", filename: "icon_32x32.png"),
    IconRepresentation(type: "ic12", filename: "icon_32x32@2x.png"),
    IconRepresentation(type: "ic07", filename: "icon_128x128.png"),
    IconRepresentation(type: "ic13", filename: "icon_128x128@2x.png"),
    IconRepresentation(type: "ic08", filename: "icon_256x256.png"),
    IconRepresentation(type: "ic14", filename: "icon_256x256@2x.png"),
    IconRepresentation(type: "ic09", filename: "icon_512x512.png"),
    IconRepresentation(type: "ic10", filename: "icon_512x512@2x.png")
]

private func bigEndianData(_ value: Int) throws -> Data {
    guard value <= Int(UInt32.max) else {
        throw IconBuildError.fileTooLarge
    }
    var encoded = UInt32(value).bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}

private func fourCharacterCode(_ value: String) throws -> Data {
    guard let data = value.data(using: .ascii), data.count == 4 else {
        throw IconBuildError.invalidFourCharacterCode(value)
    }
    return data
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icns.swift <iconset> <output.icns>\n".utf8))
    exit(64)
}

do {
    let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
    var body = Data()

    for representation in representations {
        let png = try Data(contentsOf: iconset.appendingPathComponent(representation.filename))
        body.append(try fourCharacterCode(representation.type))
        body.append(try bigEndianData(png.count + 8))
        body.append(png)
    }

    var file = try fourCharacterCode("icns")
    file.append(try bigEndianData(body.count + 8))
    file.append(body)
    try file.write(to: outputURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("make-icns: \(error)\n".utf8))
    exit(1)
}
