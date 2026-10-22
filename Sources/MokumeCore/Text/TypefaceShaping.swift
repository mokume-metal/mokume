// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation

/// 組版した 1 行の字形の並び (``Typeface/shape(_:)``)。[#2404]
///
/// **描く・幅・整列・墨の範囲は、どれもこの 1 つの結果から出す。** 別々に数えると、整列や墨の枠が
/// 数画素ずれる形で食い違う (``Typeface/advance(of:)`` と同じ理由)。
///
/// [#2404]: https://github.com/mokume-metal/mokume/issues/2404
final class ShapedLine {
    /// 1 つの字形。`x`・`y` は行の書き始めと基準線から測った位置 (画素。`y` は上向き)。
    struct Glyph {
        var resolved: ResolvedGlyph
        var x: Float
        var y: Float
    }

    let glyphs: [Glyph]
    /// 行の送り幅 (画素)。カーニング・合字を含む。
    let width: Float
    /// 字形ごとに焼き場で引いた結果の控え。頁の通し番号が一致する間だけ使える (``Typeface/placed`` と同じ約束)。
    var placed: [PlacedGlyph?]

    init(glyphs: [Glyph], width: Float) {
        self.glyphs = glyphs
        self.width = width
        self.placed = Array(repeating: nil, count: glyphs.count)
    }
}

/// 組版した字形の墨の控えの鍵。
struct ShapedInkKey: Hashable {
    var fontKey: String
    var glyph: CGGlyph
}

extension Typeface {
    /// 控える組版結果の数の上限。毎フレーム違う文字列 (数の表示など) を渡しても控えが育ちきらない。
    private static let shapedLimit = 256

    /// 1 行を組版する。**改行は含まない** (行の分け方は呼ぶ側 (`Canvas`) が決める)。
    ///
    /// CoreText が文字列を字形の列へ変える (`CTLine`)。複数のスカラでできた絵文字 (肌色の修飾子・国旗・
    /// ZWJ で繋いだ家族・異体字セレクタ・囲み) は 1 つの字形に、結合文字は基の字の字形と、位置をずらした
    /// 結合記号の字形になり、ラテンの字はカーニングが掛かる。書体が覆えない字は、CoreText が行の中で
    /// 別の書体を選ぶ。**幅は部品の幅の和にならない** (``advance(of:)`` の加法性を持たない)。
    ///
    /// 同じ文字列は控えから返す。
    func shape(_ line: String) -> ShapedLine {
        if let found = shaped[line] { return found }
        let made = makeShaped(line)
        if shaped.count >= Self.shapedLimit { shaped.removeAll(keepingCapacity: true) }
        shaped[line] = made
        return made
    }

    private func makeShaped(_ line: String) -> ShapedLine {
        let attributes = [kCTFontAttributeName: base] as CFDictionary
        guard let text = CFAttributedStringCreate(nil, line as CFString, attributes) else {
            return ShapedLine(glyphs: [], width: 0)
        }
        let ctLine = CTLineCreateWithAttributedString(text)
        let width = Float(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let basePostScript = (CTFontCopyPostScriptName(base) as String?) ?? ""
        var glyphs: [ShapedLine.Glyph] = []
        for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = (attributes[kCTFontAttributeName] as! CTFont?) ?? base
            var indices = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, 0), &indices)
            CTRunGetPositions(run, CFRangeMake(0, 0), &positions)
            // 鍵は ``glyph(for:)`` と同じ作り方。ファイルから読んだ書体の字は、同じ PostScript 名の
            // インストール済みの書体と焼き場で混ざらないよう、ファイルの同一性を鍵に含める (#2445)
            var fontKey = (CTFontCopyPostScriptName(font) as String?) ?? ""
            if let file = request.file, fontKey == basePostScript { fontKey += "#" + file.identity }
            for index in 0..<count where indices[index] != 0 {
                let resolved = ResolvedGlyph(font: font, glyph: indices[index], advance: 0, fontKey: fontKey)
                glyphs.append(
                    ShapedLine.Glyph(
                        resolved: resolved, x: Float(positions[index].x), y: Float(positions[index].y)))
            }
        }
        return ShapedLine(glyphs: glyphs, width: width)
    }

    /// 組版した字形の墨の範囲 ([#2308] と同じ測り方)。字形の座標 (書き始めと基準線から測り、上向き) で返す。
    ///
    /// 道筋で描く字形は道筋の外接、色やビットマップの字形・道筋を持たない字形は焼き場と同じ描き方で描いた墨。
    /// 控えは (書体・字形の番号) ごとで、描くのは字形の種類ごとに 1 度だけである。
    ///
    /// [#2308]: https://github.com/mokume-metal/mokume/issues/2308
    func ink(
        of glyph: ResolvedGlyph, keeping atlas: GlyphAtlas, as key: GlyphAtlas.Key
    ) -> CGRect? {
        let path = CTFontCreatePathForGlyph(glyph.font, glyph.glyph, nil)
        guard Self.measuresByDrawing(glyph, path: path) else { return path?.boundingBoxOfPath }
        let inkKey = ShapedInkKey(fontKey: glyph.fontKey, glyph: glyph.glyph)
        if let cached = shapedInks[inkKey] { return cached }
        switch Self.draw(glyph, on: atlas) {
        case .ink(let ink, let rendered):
            shapedInks[inkKey] = ink
            if let rendered { atlas.keepRendered(rendered, for: key) }
            return ink
        case .failed:
            return nil
        }
    }
}
