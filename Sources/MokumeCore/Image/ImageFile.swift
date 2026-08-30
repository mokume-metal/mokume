// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import simd

/// 画像のファイルを、作業空間の画素へ落とす。
///
/// **色の変換は描画の道具立てに任せる。** 元の絵が持つ色の記述 (プロファイル) から
/// 作業空間への変換は、伝達関数と色域の両方を含む。自前で書くと、プロファイルを
/// 持つ絵と持たない絵で結果が割れる。
///
/// 隔離の外で走れる形にしてあるのは、待たない読み込みが復号を別の仕事として
/// 回すため ([ADR-0010])。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated enum ImageFile {
    /// 復号した中身。面へ載せる前の形。
    struct Decoded: Sendable {
        var width: Int
        var height: Int
        var pixels: [SIMD4<Float16>]
    }

    /// 名前から探して復号する。
    static func decode(_ path: String) throws(ImageFailure) -> Decoded {
        let searched = candidates(for: path)
        guard let url = searched.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw .notFound(path: path, searched: searched.map(\.path))
        }
        return try decode(at: url, name: path)
    }

    /// 場所が分かっている絵を復号する。
    static func decode(at url: URL, name: String) throws(ImageFailure) -> Decoded {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw .undecodable(path: name)
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw .undecodable(path: name) }

        var pixels = [SIMD4<Float16>](repeating: .zero, count: width * height)
        let stride = width * MemoryLayout<SIMD4<Float16>>.stride
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 16, bytesPerRow: stride, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.floatComponents.rawValue
                        | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw .undecodable(path: name) }

        // 描く道具の座標は下から上へ数えるが、**並びの先頭は絵の上端**なので、
        // 並べ替えは要らない
        return Decoded(width: width, height: height, pixels: pixels)
    }

    /// 名前を、探す順に並べた場所へ広げる。
    ///
    /// **同梱した資材は、実行ファイルの隣に置かれた包みの中にある。** 道具立てが
    /// 資材をそこへ写すので、作業ディレクトリだけを見ていると見つからない。
    ///
    /// 束ねて配ったときは隣の意味が変わる — 包み (`.app`) の中では実行ファイルの隣が
    /// `Contents/MacOS/` で、資材は慣例どおり `Contents/Resources/` へ入る。だから
    /// **資源の置き場の側も同じように走査する** ([ADR-0029] 決定 4)。
    ///
    /// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
    static func candidates(for path: String) -> [URL] {
        candidates(
            for: path, workingDirectory: FileManager.default.currentDirectoryPath,
            neighbourhood: Bundle.main.bundleURL, resources: Bundle.main.resourceURL)
    }

    /// 探す場所を並べる (どこを起点にするかを渡せる形)。
    ///
    /// 起点を渡せるのは、**道具立てが資材をどこへ置くか**を検査から確かめるため。
    /// 実際に組み上げた結果の隣を起点にして、ここが返す並びに入っていることを見る。
    static func candidates(
        for path: String, workingDirectory: String, neighbourhood: URL, resources: URL?
    ) -> [URL] {
        if path.hasPrefix("/") { return [URL(fileURLWithPath: path)] }

        var urls: [URL] = []
        urls.append(URL(fileURLWithPath: workingDirectory).appendingPathComponent(path))
        if let resources {
            urls.append(resources.appendingPathComponent(path))
        }
        for root in [neighbourhood, resources].compactMap({ $0 }) {
            urls.append(contentsOf: bundled(path, in: root))
        }
        urls.append(neighbourhood.appendingPathComponent(path))
        return urls
    }

    /// 置き場に並んだ包みの中を、探す場所として広げる。
    private static func bundled(_ path: String, in root: URL) -> [URL] {
        let listing =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
        var urls: [URL] = []
        for bundle in listing.sorted(by: { $0.path < $1.path })
        where bundle.pathExtension == "bundle" {
            urls.append(bundle.appendingPathComponent(path))
            urls.append(
                bundle.appendingPathComponent("Contents/Resources").appendingPathComponent(path))
        }
        return urls
    }
}
