// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation

/// ファイルから読んだ書体 ([#2445])。``SketchPart/loadFont(_:)`` が返し、``SketchPart/textFont(_:)-(Font)``
/// で選ぶ。
///
/// **手本の `PFont`・`p5.Font` に当たる。** Processing の `createFont(path, size)` と p5.js の
/// `loadFont(path)` が返すものと同じ役目で、大きさは持たない (大きさは ``SketchPart/textSize(_:)`` が
/// 決める)。名前が手本から離れて `Font` なのは、SwiftUI と衝突する名前は取ってよいと決めたため
/// ([ADR-0020] 決定 1 の 2026-10-14 の改訂)。SwiftUI を import するファイルでは、`mokume.Font` と
/// 書けば解ける (`Image`・`Shape` と同じ扱い)。
///
/// ## 同じファイルは同じ値
///
/// **同じファイルを、更新されないまま何度読んでも、読んだ値は等しい。** 描いた字は値を鍵に焼き場へ
/// 預けるので、毎フレーム読み直しても同じ字形を使い回す (それでも ``SketchPart/loadFont(_:)`` は
/// `setup()` で 1 度読む)。ファイルを差し替えれば (更新時刻が変わる)、次に読んだ値は別のものになる。
///
/// ## プロセスへ登録しない
///
/// 読んだ書体は、この環境の書体として登録しない。**同じ名前の書体が入っていても、
/// ``SketchPart/textFont(_:)-(String)`` に渡す名前の結果は変わらず、他のアプリにも見えない。**
///
/// [#2445]: https://github.com/mokume-metal/mokume/issues/2445
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public struct Font: Hashable, Sendable, CustomStringConvertible {
    /// ``SketchPart/loadFont(_:)`` へ渡した名前。説明にだけ使い、等しさには入れない。
    let path: String
    /// 読んだファイルの同一性 — 解けた場所と更新時刻。等しさと、焼き場の鍵はこれで決まる。
    let identity: String
    /// ファイルが持つ面。**可変書体は 1 つ** (太さは面を選ばず軸で動かす)。
    let faces: [Face]
    /// ファイルが可変書体か。
    let isVariable: Bool

    /// ファイルの中の 1 つの面。
    ///
    /// CoreText の記述子は不変で、どのスレッドからも読める。型の上で `Sendable` と宣言されて
    /// いないだけなので、ここで保証する。
    struct Face: @unchecked Sendable {
        let descriptor: CTFontDescriptor
        let trait: TypefaceWeight.Trait
    }

    public var description: String { "Font(\"\(path)\")" }

    public static func == (lhs: Font, rhs: Font) -> Bool { lhs.identity == rhs.identity }

    public func hash(into hasher: inout Hasher) { hasher.combine(identity) }

    /// 名前から探して、ファイルを書体として読む。
    ///
    /// 探し方は画像と同じ (``ImageFile/locate(_:)``)。登録はしない。
    static func load(_ path: String) throws(FontFailure) -> Font {
        let url: URL
        do {
            url = try ImageFile.locate(path)
        } catch {
            switch error {
            case .notFound(let path, let searched): throw .notFound(path: path, searched: searched)
            case .unopenable(let path, let location, let reason):
                throw .unopenable(path: path, location: location, reason: reason)
            default: throw .unreadable(path: path)
            }
        }
        if let refusal = AssetOpening.refusal(at: url) {
            throw .unopenable(path: path, location: refusal.location, reason: refusal.reason)
        }
        guard
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor],
            let first = descriptors.first
        else { throw .unreadable(path: path) }

        let stamp = FileStamp.of(url)
        let identity =
            "\(url.standardizedFileURL.path)@\(stamp?.seconds ?? 0).\(stamp?.nanoseconds ?? 0)"

        // **可変書体は、名前つきのインスタンスの全部が返る** (`SFNS.ttf` は 369 個で、先頭は最も細い
        // 面)。先頭を使うと、何も頼まない書体が細い面になる。可変なら面は 1 つで、既定の面は軸の
        // 既定値で作る (``Typeface/makeFileFont(_:size:weight:bold:italic:)``)
        let probe = CTFontCreateWithFontDescriptor(first, 12, nil)
        if !TypefaceWeight.axes(of: probe).isEmpty {
            let face = Face(descriptor: first, trait: TypefaceWeight.trait(of: probe))
            return Font(path: path, identity: identity, faces: [face], isVariable: true)
        }
        let faces = descriptors.map { descriptor in
            Face(
                descriptor: descriptor,
                trait: TypefaceWeight.trait(of: CTFontCreateWithFontDescriptor(descriptor, 12, nil)))
        }
        return Font(path: path, identity: identity, faces: faces, isVariable: false)
    }
}
