//
//  TarBz2Extractor.swift
//  SiriApp
//
//  tar.bz2 extraction using system libbz2 (via bridging header).
//  Ported from Android: ModelManager.kt tar extraction logic.
//

import Foundation

enum TarBz2Extractor {
    private static let tarBlockSize = 512

    /// Known file name mappings (auto-rename after extraction)
    static let renameMap: [String: String] = [
        "model-steps-3.onnx": "model.onnx",
        "vocos-22khz-univ.onnx": "vocos.onnx",
    ]

    /// Extract tar.bz2 file to destination directory.
    /// Strips the first path component (--strip-components=1).
    static func extract(
        sourceURL: URL,
        destinationDir: URL,
        progress: ((Float) -> Void)? = nil
    ) throws {
        let fileData = try Data(contentsOf: sourceURL)

        // Decompress bzip2
        let decompressed = try decompressBz2(fileData, progress: { p in
            progress?(p * 0.5)
        })

        // Extract tar
        try extractTar(
            data: decompressed,
            to: destinationDir,
            totalDecompressedSize: decompressed.count,
            progress: { p in
                progress?(0.5 + p * 0.5)
            }
        )

        // Rename known files
        let fm = FileManager.default
        for (oldName, newName) in renameMap {
            let src = destinationDir.appendingPathComponent(oldName)
            let dst = destinationDir.appendingPathComponent(newName)
            if fm.fileExists(atPath: src.path) && !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
    }

    // MARK: - Bzip2 Decompression

    private static func decompressBz2(
        _ data: Data,
        progress: ((Float) -> Void)? = nil
    ) throws -> Data {
        // Use libbz2 via bridging header (<bzlib.h>)
        let totalSize = data.count
        var result = Data()

        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let baseAddress = ptr.baseAddress else {
                throw NSError(domain: "TarBz2", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to read input data"])
            }

            var bzStream = bz_stream()
            bzStream.next_in = UnsafeMutablePointer<Int8>(
                mutating: baseAddress.assumingMemoryBound(to: Int8.self)
            )
            bzStream.avail_in = UInt32(totalSize)

            guard BZ2_bzDecompressInit(&bzStream, 0, 0) == BZ_OK else {
                throw NSError(domain: "TarBz2", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "BZ2 decompress init failed"])
            }
            defer { BZ2_bzDecompressEnd(&bzStream) }

            let outBufSize = 65536
            var outBuf = [Int8](repeating: 0, count: outBufSize)

            try outBuf.withUnsafeMutableBufferPointer { buffer in
                bzStream.next_out = buffer.baseAddress
                bzStream.avail_out = UInt32(outBufSize)

                while true {
                    let ret = BZ2_bzDecompress(&bzStream)
                    let produced = outBufSize - Int(bzStream.avail_out)

                    if produced > 0 {
                        result.append(contentsOf: (0..<produced).map { UInt8(bitPattern: buffer[$0]) })
                        progress?(Float(bzStream.total_in_lo32) / Float(totalSize))
                    }

                    if ret == BZ_STREAM_END { break }
                    if ret != BZ_OK {
                        throw NSError(domain: "TarBz2", code: Int(ret),
                            userInfo: [NSLocalizedDescriptionKey: "BZ2 decompress error: \(ret)"])
                    }

                    // Reset output buffer for next iteration
                    bzStream.next_out = buffer.baseAddress
                    bzStream.avail_out = UInt32(outBufSize)
                }
            }
        }

        return result
    }

    // MARK: - Tar Extraction

    private static func extractTar(
        data: Data,
        to destDir: URL,
        totalDecompressedSize: Int,
        progress: ((Float) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        var offset = 0

        while offset + tarBlockSize <= data.count {
            let header = data.subdata(in: offset..<offset + tarBlockSize)
            offset += tarBlockSize

            // Read file name (bytes 0-99)
            guard let name = String(data: header[0..<100], encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) else {
                break
            }

            // Empty name = end of archive
            guard !name.isEmpty else { break }

            // Read file size (bytes 124-135, octal string)
            guard let sizeStr = String(data: header[124..<136], encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")),
                  let size = Int(sizeStr, radix: 8) else {
                break
            }

            // Strip first directory component
            var relativePath = name
            if let slashRange = relativePath.range(of: "/") {
                relativePath = String(relativePath[slashRange.upperBound...])
            }
            guard !relativePath.isEmpty else {
                // Skip to next block boundary
                if size > 0 {
                    offset += ((size + tarBlockSize - 1) / tarBlockSize) * tarBlockSize
                }
                continue
            }

            let destPath = destDir.appendingPathComponent(relativePath)

            if name.hasSuffix("/") || size == 0 {
                // Directory
                try fm.createDirectory(at: destPath, withIntermediateDirectories: true)
            } else {
                // File
                try fm.createDirectory(
                    at: destPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let fileData = data.subdata(in: offset..<offset + size)
                try fileData.write(to: destPath)

                // Pad to 512-byte boundary
                let paddedSize = ((size + tarBlockSize - 1) / tarBlockSize) * tarBlockSize
                offset += paddedSize
            }

            progress?(Float(offset) / Float(totalDecompressedSize))
        }
    }
}
