// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreImage
import Foundation

/// `--remote` の URL の QR コード。CoreImage の `CIQRCodeGenerator` で作り、端末と窓に描く。
///
/// 依存を増やさないために、符号化は OS に任せ、描くのは自前で持つ。
nonisolated struct QRCode: Equatable, Sendable {
    /// 暗いモジュールが `true`。周りの静寂域は含まない。
    let modules: [[Bool]]

    /// 周りに足す静寂域のモジュール数。規格は 4 だが、端末の幅を食うので 2 にする
    /// (白地を明示して描くので、スマホのカメラは 2 で読める)。
    static let quietZone = 2

    /// `text` を符号化する。誤り訂正は M (15 %)。作れなければ `nil`。
    init?(_ text: String) {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        context.render(
            image, toBitmap: &pixels, rowBytes: width, bounds: extent, format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray())
        let rows = (0..<height).map { row in (0..<width).map { pixels[row * width + $0] < 128 } }
        self.init(trimming: rows)
    }

    /// 周りの明るいモジュールを落として持つ (生成器が付ける静寂域の幅に頼らない)。
    init?(trimming rows: [[Bool]]) {
        let dark = rows.indices.filter { rows[$0].contains(true) }
        guard let top = dark.first, let bottom = dark.last else { return nil }
        let columns = rows.flatMap { row in row.indices.filter { row[$0] } }
        guard let left = columns.min(), let right = columns.max() else { return nil }
        modules = rows[top...bottom].map { Array($0[left...right]) }
    }

    /// 静寂域を含めた行列。
    var padded: [[Bool]] {
        let side = modules.count + QRCode.quietZone * 2
        let blank = [Bool](repeating: false, count: side)
        let margin = [Bool](repeating: false, count: QRCode.quietZone)
        return [[Bool]](repeating: blank, count: QRCode.quietZone)
            + modules.map { margin + $0 + margin }
            + [[Bool]](repeating: blank, count: QRCode.quietZone)
    }

    /// 端末に描く行。上下 2 モジュールを半角ブロック 1 文字に詰める。
    ///
    /// `colored` なら白地に黒の色を明示する — 端末の配色 (暗い背景) のまま描くと明暗が逆になり、
    /// カメラが読めないことがある。色を付けない (端末でない出力) ときは、明るい背景を仮定する。
    func terminalLines(colored: Bool) -> [String] {
        let rows = padded
        var lines: [String] = []
        var row = 0
        while row < rows.count {
            let upper = rows[row]
            let lower = row + 1 < rows.count ? rows[row + 1] : [Bool](repeating: false, count: upper.count)
            var line = colored ? "\u{1B}[30;47m" : ""
            for column in upper.indices {
                switch (upper[column], lower[column]) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            if colored { line += "\u{1B}[0m" }
            lines.append(line)
            row += 2
        }
        return lines
    }

    /// 窓に置く絵。1 モジュールを `scale` 画素の正方形で描き、補間でぼかさない。
    func image(scale: Int) -> CGImage? {
        let rows = padded
        let side = rows.count * scale
        guard side > 0,
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(gray: 0, alpha: 1)
        for (row, modules) in rows.enumerated() {
            for (column, dark) in modules.enumerated() where dark {
                // CGContext の原点は左下なので、行を上から数え直す
                context.fill(
                    CGRect(x: column * scale, y: side - (row + 1) * scale, width: scale, height: scale))
            }
        }
        return context.makeImage()
    }
}
