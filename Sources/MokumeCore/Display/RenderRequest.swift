// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

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
/// パスもそのまま運べる。JSON にしないのは、面の仕様 (`Schemas/`) を持つほどの形ではなく、
/// 道具と子が**同じ版のこの型**で読み書きするからである (道具は `package` の口から組む)。
///
/// [#1282]: https://github.com/mokume-metal/mokume/issues/1282
package nonisolated struct RenderRequest: Equatable, Sendable {
    /// 1 秒あたりの枚数。**時計と撮る係の両方がこれに従う** — 作品の
    /// ``SketchSettings/frameRate`` と違ってよい。
    package let frameRate: Int
    /// 描く枚数。描き終えたら子は自分で終わる。
    package let frameCount: Int
    /// 書き出す先。綴りが形を決める (`.mov` なら動画、ファイル名に `#` の並びを含めば連番)。
    ///
    /// **絶対パスで渡す。** 子の作業ディレクトリはスケッチの場所で、打った場所ではない。
    package let destination: String

    /// 組む。**書き出せない組は作らない** — 子が受け取ってから断ると、窓を持たない子は
    /// 何も書かずに終わることになる。行き先と fps の規則は撮る係のもの
    /// (``FrameRecorder/accepts(_:frameRate:)``)。`.mov` へ刻みより速く書く組もここで断る ([#2307])。
    ///
    /// [#2307]: https://github.com/mokume-metal/mokume/issues/2307
    package init?(frameRate: Int, frameCount: Int, destination: String) {
        guard frameRate > 0, frameCount > 0,
            Self.accepts(destination: destination, frameRate: frameRate)
        else {
            return nil
        }
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.destination = destination
    }

    /// 行き先の綴りを、書き出せる形として受けるか。規則は撮る係のもの
    /// (``FrameRecorder/accepts(_:)``) で、組むときもこれで見る。
    ///
    /// **道具は、打った綴りのままもこれで見る** ([#2313])。行き先は絶対パスにしてから渡すが、
    /// 絶対パスにすると末尾の `/` と `.`・`..` が消え、番号の場所を探す最後の部品が打った
    /// 綴りと変わる (`take#1/` が `<打った場所>/take#1` になる)。
    ///
    /// [#2313]: https://github.com/mokume-metal/mokume/issues/2313
    package static func accepts(destination: String) -> Bool {
        FrameRecorder.accepts(destination)
    }

    /// `.mov` に書ける fps の上限。規則は撮る係のもの (``FrameRecorder/movieFrameRateLimit``・[#2307])。
    ///
    /// [#2307]: https://github.com/mokume-metal/mokume/issues/2307
    package static let movieFrameRateLimit = FrameRecorder.movieFrameRateLimit

    /// 行き先の綴りと fps の組を、書き出せる組として受けるか。規則は撮る係のもの
    /// (``FrameRecorder/accepts(_:frameRate:)``) で、組むときもこれで見る。
    package static func accepts(destination: String, frameRate: Int) -> Bool {
        FrameRecorder.accepts(destination, frameRate: frameRate)
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
    package var environmentValue: String { "\(frameRate):\(frameCount):\(destination)" }

    /// 環境変数の値から読む。**読めなければ `nil`。**
    package init?(environmentValue: String) {
        let parts = environmentValue.split(
            separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let rate = Int(parts[0]), let count = Int(parts[1]) else {
            return nil
        }
        self.init(frameRate: rate, frameCount: count, destination: String(parts[2]))
    }

    /// 起動の瞬間に決まる頼み。**合図が無ければ `nil`** (いつもの窓の経路)。
    ///
    /// **環境を読むのはここだけ** — 一覧 ([StartupReads]) がこのファイルを名指ししている。
    ///
    /// 読めない値は黙って捨てない。窓の経路へ倒すので、書き出したつもりの人には窓が出る
    /// ことで分かるが、なぜ窓が出たかはここで言わないと分からない。
    static func startup(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RenderRequest? {
        guard let value = environment[StartupReads.render.key] else { return nil }
        guard let request = RenderRequest(environmentValue: value) else {
            Diagnostics.warn(
                "\(StartupReads.render.key) is set but cannot be read, or asks for something that "
                    + "cannot be written (\(value)) — running as usual, with a window. Its form is "
                    + "<fps>:<frames>:<where to write>, and a .mov takes at most \(movieFrameRateLimit) "
                    + "frames per second")
            return nil
        }
        return request
    }
}
