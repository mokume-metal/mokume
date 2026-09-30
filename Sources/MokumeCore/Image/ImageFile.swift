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

    /// 読んだ結果と、**どこから読んだか**。控えが鮮度を見るのに要る ([#886])。
    ///
    /// [#886]: https://github.com/mokume-metal/mokume/issues/886
    struct Read: Sendable {
        var url: URL
        var stamp: FileStamp?
        var decoded: Decoded
    }

    /// 名前から探して復号する。
    static func decode(_ path: String) throws(ImageFailure) -> Decoded {
        try decode(at: locate(path), name: path)
    }

    /// 名前から探して復号し、**読んだ場所と更新時刻も返す。**
    ///
    /// 隔離の外で 1 度に済ませる形にしてあるのは、待たない読み込みが探索・更新時刻の
    /// 読み・復号をまとめて別の仕事へ回すためである。
    static func read(_ path: String) throws(ImageFailure) -> Read {
        let url = try locate(path)
        let stamp = stamp(of: url)
        return Read(url: url, stamp: stamp, decoded: try decode(at: url, name: path))
    }

    /// 名前を、実際に在るファイルへ解く。
    ///
    /// 復号と分けてあるのは、**控えが「同じファイルか」を確かめるため** — 場所が分かれば
    /// 復号せずに更新時刻だけを見られる ([#886])。
    ///
    /// [#886]: https://github.com/mokume-metal/mokume/issues/886
    static func locate(_ path: String) throws(ImageFailure) -> URL {
        let searched = candidates(for: path)
        guard let url = searched.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw .notFound(path: path, searched: searched.map(\.path))
        }
        return url
    }

    /// ファイルの更新時刻。読めなければ nil。
    ///
    /// **控えの鮮度はこれで見る。** 名前だけを鍵にすると、走らせたまま絵を差し替える
    /// 書き方が黙って効かなくなる ([#886])。読めなかったときに nil を返すのは、
    /// 読み直す側 (安全な側) へ倒すためである。
    ///
    /// [#886]: https://github.com/mokume-metal/mokume/issues/886
    static func stamp(of url: URL) -> FileStamp? {
        FileStamp.of(url)
    }

    /// 場所が分かっている絵を復号する。
    ///
    /// ## 半精度の上限を越える成分
    ///
    /// **CoreGraphics は半精度の文脈へ描くとき、上限 (65504) を越える成分を ±inf にする**
    /// (65520 以上・[#1873] の実測)。HDR の絵 (32 ビット浮動小数の TIFF・OpenEXR) はここへ届く
    /// ので、そのまま面へ置くと、その上に描いた不透明な図形が inf × 0 で NaN になって黒く抜ける。
    /// 面へ置く他の経路と同じく上限で止める (``HalfSurface``) が、**受け取った時点で元の値が
    /// 残っていない**ので、受け取った直後に通しても直らない。
    ///
    /// だから出力に非有限の成分が出たときだけ、32 ビット浮動小数の文脈で描き直し、**非有限
    /// だった成分だけ**を ``HalfSurface/component(_:)`` を通して半精度へ移す。ふつうの絵は描き直さず、
    /// 描き直した絵でも有限だった成分は最初の描き方のままなので、結果は変わらない。
    ///
    /// [#1873]: https://github.com/mokume-metal/mokume/issues/1873
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
        let drawn = pixels.withUnsafeMutableBytes {
            draw(image, into: $0, bitsPerComponent: 16, byteOrder: .byteOrder16Little)
        }
        guard drawn else { throw .undecodable(path: name) }

        if hasNonFinite(pixels) {
            var wide = [SIMD4<Float>](repeating: .zero, count: width * height)
            let redrawn = wide.withUnsafeMutableBytes {
                draw(image, into: $0, bitsPerComponent: 32, byteOrder: .byteOrder32Little)
            }
            guard redrawn else { throw .undecodable(path: name) }
            for index in pixels.indices {
                for lane in 0..<4 where !pixels[index][lane].isFinite {
                    pixels[index][lane] = Float16(HalfSurface.component(wide[index][lane]))
                }
            }
        }

        // 描く道具の座標は下から上へ数えるが、**並びの先頭は絵の上端**なので、
        // 並べ替えは要らない
        return Decoded(width: width, height: height, pixels: pixels)
    }

    /// 作業空間 (線形・拡張色域・乗算済み) の浮動小数の文脈へ、絵を等倍で描く。
    ///
    /// 成分の幅 (16 ビットか 32 ビット) だけを呼び手が選ぶ。色の変換は描く道具立てが行う。
    private static func draw(
        _ image: CGImage, into buffer: UnsafeMutableRawBufferPointer, bitsPerComponent: Int,
        byteOrder: CGBitmapInfo
    ) -> Bool {
        let width = image.width
        let height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: width * 4 * bitsPerComponent / 8, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.floatComponents.rawValue | byteOrder.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    /// 成分に無限か NaN があるか。**指数部がすべて 1 なら非有限** (半精度の 5 ビット)。
    ///
    /// 1 成分ずつ `isFinite` を問うと、大きな絵で debug の実行が長くなる。ビットを直に見る。
    private static func hasNonFinite(_ pixels: [SIMD4<Float16>]) -> Bool {
        pixels.withUnsafeBytes { bytes in
            bytes.bindMemory(to: UInt16.self).contains { $0 & 0x7C00 == 0x7C00 }
        }
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
    ///
    /// **列挙はパスの版で行う。** URL の版 (`contentsOfDirectory(at:)`) は、置き場が
    /// ディレクトリへの symlink だと開けずに投げる。SwiftPM の `.build/release` はまさに
    /// それなので、手で `./.build/release/<名前>` と打つと包みが候補から丸ごと落ちていた
    /// ([#1330])。
    ///
    /// **候補は起点の綴りのまま組み、symlink を解かない。** 解いてから組むと、返す綴りが
    /// 比べる側の綴りと割れる ([#1255])。
    ///
    /// [#1330]: https://github.com/mokume-metal/mokume/issues/1330
    /// [#1255]: https://github.com/mokume-metal/mokume/issues/1255
    private static func bundled(_ path: String, in root: URL) -> [URL] {
        let listing =
            ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .map { root.appendingPathComponent($0) }
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
