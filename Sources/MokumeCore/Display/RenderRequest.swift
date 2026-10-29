// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 決めた枚数を、決めた速さの時刻で書き出す頼み (`mokume render`・[#1282])。
///
/// ## なぜ要るのか
///
/// 画面に出す経路の時計は実時間なので、走らせながら `beginRecord` で撮ると**重いフレームは
/// 長く映るだけ**で、同じ引数から同じ動きが出ない。フレーム番号から導く時計も、ProRes 4444 の
/// 書き出しも本体にあるのに、作品を走らせる入口 (`Sketch.main()`) からは届かなかった。
///
/// ## 誰が決めるか
///
/// **道具が決め、環境変数で子へ渡す** (``StartupReads/render``)。作品のコードは 1 行も
/// 変えない — 書き出しのためだけに、作品へ 2 つ目の入口を持たせないためである。
///
/// ## 渡す形
///
/// 1 つの環境変数に `<fps>:<枚数>:<行き先>` と並べる。行き先を最後に置くので、`:` を含む
/// パスもそのまま運べる。**倍率を掛けるとき (``scale`` が 2 以上) だけ**、行き先の前に
/// `<倍率>:` を挟む (`<fps>:<枚数>:<倍率>:<行き先>`)。行き先は絶対パスで渡すので (`/` で始まる)、
/// 数字で始まる倍率と取り違えない。JSON にしないのは、面の仕様 (`Schemas/`) を持つほどの形ではなく、
/// 道具と子が**同じ版のこの型**で読み書きするからである (道具は `package` の口から組む)。
///
/// [#1282]: https://github.com/mokume-metal/mokume/issues/1282
package nonisolated struct RenderRequest: Equatable, Sendable {
    /// 1 秒あたりの枚数。**時計と撮る係の両方がこれに従う** — 作品の
    /// ``SketchSettings/frameRate`` と違ってよい。
    package let frameRate: Int
    /// 描く枚数。描き終えたら子は自分で終わる。
    package let frameCount: Int
    /// 出す画素の倍率 (1 以上の整数・[#2441])。**座標は変えず、出す画素だけを倍率の 2 乗に増やす。**
    /// 2 なら 1920×1080 の作品が 3840×2160 の絵になる。1 は書き出さないときと同じ。
    ///
    /// [#2441]: https://github.com/mokume-metal/mokume/issues/2441
    package let scale: Int
    /// 書き出す先。綴りが形を決める (`.mov` なら動画、ファイル名に `#` の並びを含めば連番)。
    ///
    /// **絶対パスで渡す。** 子の作業ディレクトリはスケッチの場所で、打った場所ではない。
    package let destination: String

    /// 組む。**書き出せない組は作らない** — 子が受け取ってから断ると、窓を持たない子は
    /// 何も書かずに終わることになる。行き先と fps の規則は撮る係のもの
    /// (``FrameRecorder/accepts(_:frameRate:)``)。`.mov` へ刻みより速く書く組もここで断る ([#2307])。
    ///
    /// [#2307]: https://github.com/mokume-metal/mokume/issues/2307
    package init?(frameRate: Int, frameCount: Int, scale: Int = 1, destination: String) {
        guard frameRate > 0, frameCount > 0, Self.scales.contains(scale),
            Self.accepts(destination: destination, frameRate: frameRate)
        else {
            return nil
        }
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.scale = scale
        self.destination = destination
    }

    /// 受ける倍率。**1 以上の整数で、倍率だけで面の一辺の上限を越えないもの。** 作品の大きさを掛けた
    /// 後の上限は、道具が作品の大きさをビルドの前には知らないので、子の組み立てが断る
    /// (``SketchRuntime/outputTarget(gpu:width:height:scale:)``)。
    package static let scales = 1...RenderDevice.maxTextureSide

    /// 行き先の綴りを、書き出せる形として受けるか。規則は撮る係のもの
    /// (``FrameRecorder/accepts(_:)``) で、組むときもこれで見る。
    ///
    /// **道具は、打った綴りのままもこれで見る** ([#2313])。行き先は絶対パスにしてから渡すが、
    /// 絶対パスにすると末尾の `/` と `.`・`..` が消え、番号の場所を探す最後の部品が打った
    /// 綴りと変わる (`take#1/` が `<打った場所>/take#1` になる)。
    ///
    /// [#2313]: https://github.com/mokume-metal/mokume/issues/2313
    package static func accepts(destination: String) -> Bool {
        FrameRecorder.acceptsForRender(destination)
    }

    /// 行き先が配る形 (GIF・MP4) か ([#2440])。配る形は、同じ引数から書いても画素が一致するとは約束しない。
    /// 道具が書き終わりの 1 行で名乗る。
    ///
    /// [#2440]: https://github.com/mokume-metal/mokume/issues/2440
    package static func isDistribution(destination: String) -> Bool {
        FrameRecorder.distribution(of: destination) != nil
    }

    /// 行き先が GIF か。道具が、GIF の fps の規則を断る文面を選ぶのに使う ([#2440])。
    ///
    /// [#2440]: https://github.com/mokume-metal/mokume/issues/2440
    package static func isGIF(destination: String) -> Bool {
        FrameRecorder.distribution(of: destination) == .gif
    }

    /// GIF が受けない fps を断る理由 (1 文)。**使える近い fps を名指す。**
    package static func gifRateReason(frameRate: Int) -> String {
        FrameRecorder.distributionRateReason(.gif, frameRate: frameRate)
    }

    /// `.mov` に書ける fps の上限。規則は撮る係のもの (``FrameRecorder/movieFrameRateLimit``・[#2307])。
    ///
    /// [#2307]: https://github.com/mokume-metal/mokume/issues/2307
    package static let movieFrameRateLimit = FrameRecorder.movieFrameRateLimit

    /// 行き先の綴りと fps の組を、書き出せる組として受けるか。規則は撮る係のもの
    /// (``FrameRecorder/accepts(_:frameRate:)``) で、組むときもこれで見る。
    package static func accepts(destination: String, frameRate: Int) -> Bool {
        FrameRecorder.acceptsForRender(destination, frameRate: frameRate)
    }

    /// 行き先のファイル名が、作れない長さか。作れれば `nil` ([#2774])。規則は撮る係のもの
    /// (``FrameRecorder/nameTooLong(_:frameCount:)``) で、**連番は最後の枚の名前** (番号が桁に
    /// 収まらずに伸びた後) で見る。
    ///
    /// 道具は子を起こす前 (ビルドの前) にこれで断る。子の中で落ちると、ビルドの後に、長さが理由だと
    /// 言われずに分かる。
    ///
    /// [#2774]: https://github.com/mokume-metal/mokume/issues/2774
    package static func nameTooLong(destination: String, frameCount: Int) -> LongFileName? {
        FrameRecorder.nameTooLong(destination, frameCount: frameCount)
    }

    /// ``nameTooLong(destination:frameCount:)`` の理由 (1 文)。
    package static func tooLongReason(_ long: LongFileName) -> String {
        FrameRecorder.tooLongReason(long)
    }

    /// 環境変数に載せる値。
    package var environmentValue: String {
        scale == 1
            ? "\(frameRate):\(frameCount):\(destination)"
            : "\(frameRate):\(frameCount):\(scale):\(destination)"
    }

    /// 環境変数の値から読む。**読めなければ `nil`。**
    package init?(environmentValue: String) {
        let parts = environmentValue.split(
            separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let rate = Int(parts[0]), let count = Int(parts[1]) else {
            return nil
        }
        // 倍率があれば、行き先の前に `<倍率>:` が挟まっている (行き先は `/` で始まる絶対パス)
        var scale = 1
        var destination = parts[2]
        if let colon = destination.firstIndex(of: ":"), let given = Int(destination[..<colon]) {
            scale = given
            destination = destination[destination.index(after: colon)...]
        }
        self.init(frameRate: rate, frameCount: count, scale: scale, destination: String(destination))
    }

    /// 起動の瞬間に決まる頼み。**合図が無ければ `nil`** (いつもの窓の経路)。
    ///
    /// **環境を読むのはここだけ** — 一覧 ([StartupReads]) がこのファイルを名指ししている。
    ///
    /// **合図が在って読めない値は、窓へ倒さず断る** ([#2481])。`mokume render` を打った人に窓は
    /// 役に立たない — 窓を開いて 0 で終わると、道具は書き出せたと読み、何も書かれていないのに
    /// 頼んだ枚数を名乗っていた。投げた失敗は組み立ての失敗と同じ道を通り、``Sketch/main()`` が
    /// 窓を開かずに理由を標準エラーへ出して 0 以外で終わる。道具はそれを子の失敗として断る
    /// (`renderIncomplete`)。
    ///
    /// 読めないのは、形が違う値と、書き出せない組 (fps の上限を越える `.mov` など) である。
    /// 道具と依存の版がずれたとき、手で値を置いたときに起きる。
    ///
    /// [#2481]: https://github.com/mokume-metal/mokume/issues/2481
    static func startup(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(RenderFailure) -> RenderRequest? {
        guard let value = environment[StartupReads.render.key] else { return nil }
        guard let request = RenderRequest(environmentValue: value) else {
            throw .unreadableRenderRequest(value: value)
        }
        return request
    }
}
