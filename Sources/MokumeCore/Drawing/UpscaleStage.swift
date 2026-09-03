// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics
import simd

/// 描く細かさの絵を、出す細かさへ広げる段。
///
/// [ADR-0015] 決定 5 のとおり**パイプラインの段**であって、画面へ出すときの都合ではない。
/// だから画面・保存・観測のどの出口も、同じ広げた絵を受け取る ([ADR-0023] 決定 2)。
///
/// ## 広げるのは自前の断片である
///
/// 土台が用意する拡大器 (MetalFX) は採らなかった。3 つとも実測した結果である
/// ([ADR-0015] の追補):
///
/// - **検証レイヤを有効にすると必ず異常終了する** (`_outputTextureBarrierStages not set`)。
///   この値を設定する口が公開ヘッダにも実行時のクラスにも無く、避けようがない。
///   手元の主ゲート (`make ci-check`) は検証レイヤを常時入れているので、拡大の検査が
///   1 本も通せなくなる
/// - **不透明度を保たない** — 完全に透明な画素も不透明度 1 で返す ([ADR-0023] 決定 4 に反する)
/// - **絵が土台の版に依存する** — 同じコードから同じ絵という設計目標
///   ([ADR-0001] 原則 2) を、こちらから確かめられない形で破る
///
/// 自前の三次補間なら 3 つとも起きない。代表シーンの台帳に拡大の行を置けるのもこれによる。
///
/// ## 時間方向は「揺らして重ねる」
///
/// 1 フレームごとに描く位置を画素の内側で少し揺らし、広げるときに戻してから前の結果へ
/// 重ねる。止まっている絵では細かさが積み上がり、**動くものは尾を引く**。
/// 前のフレームに依るので単一フレームの再現は失われる — [ADR-0015] 決定 2 の代償である。
///
/// ## 置き場は 1 度だけ確保する
///
/// 前の結果の置き場は組み立てのとき 1 度きり ([ADR-0023] 決定 5)。空間方向は 1 枚も持たない。
///
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
/// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
final class UpscaleStage {
    /// 何で埋めるか。
    let kind: Upscale

    /// 前のフレームの結果。時間方向のときだけ持つ。
    ///
    /// 色だけの絵 (``StageImage``)。混ぜる相手として読まれ、出した絵を写して控えるだけ
    /// なので、奥行きも CPU から読む口も要らない (#753)。
    let history: StageImage?

    /// 描く先の大きさ (画素)。揺らす量をここで測る。
    private let drawnWidth: Int
    private let drawnHeight: Int

    /// いま何枚目か。揺らす位置と、前の結果を捨てるかを決める。
    private(set) var framesScaled = 0

    /// 揺らしを何枚で 1 周させるか。**2 の冪にしない** — 半端な周期のほうが、
    /// 短い区間を切り取ったときの偏りが小さい。
    static let jitterPeriod = 8

    /// いまのフレームの重み。最初の 1 枚は前が無いので 1 (前を捨てる)。
    ///
    /// 積み上げの速さと、動くものの尾の長さは表裏である。8 枚ぶんで 1 周する揺らしに
    /// 対して、8 枚で概ね収まる重みを選ぶ。
    var weight: Float { framesScaled == 0 ? 1 : 0.2 }

    init(gpu: RenderDevice, kind: Upscale, from source: RenderTarget, to output: RenderTarget)
        throws(RenderFailure)
    {
        self.kind = kind
        self.drawnWidth = source.width
        self.drawnHeight = source.height
        switch kind {
        case .spatial:
            self.history = nil
        case .temporal:
            // 最初のフレームから混ぜる相手として読まれるので、透明な黒から始める
            self.history = try StageImage(
                gpu: gpu, width: output.width, height: output.height, startingTransparent: true)
            // **代償は有効化の時点で告げる** ([ADR-0015] 決定 2)。doc に書くだけでは、
            // 決定論が要る使い方をしている人が読むとは限らない
            Diagnostics.warn(
                "時間方向の拡大を有効にしました。"
                    + "同じフレーム番号から同じ絵は出ません (前のフレームの結果に依ります)。"
                    + "止まっている絵は細かくなり、動くものは尾を引きます")
        }
    }

    /// このフレームで描く位置をどれだけ揺らすか (描く先の画素)。
    ///
    /// 空間方向では揺らさない — 揺らした時点で、同じ入力から同じ絵という前提が崩れる。
    var jitter: SIMD2<Float> {
        guard kind.usesFrameHistory else { return .zero }
        let index = framesScaled % Self.jitterPeriod
        // ハルトン列。**少ない枚数でも画素の中に均されて並ぶ**ので、8 枚で角が取れる
        return SIMD2(
            Self.radicalInverse(index + 1, base: 2) - 0.5,
            Self.radicalInverse(index + 1, base: 3) - 0.5)
    }

    /// 揺らした分を、入りの絵を読む位置 (0…1) へ写したもの。
    ///
    /// 描く位置を右へずらして描いた絵は、右へずれて写っている。読む位置を同じだけ
    /// 右へずらせば元の位置が読める。**戻すのは広げる補間の中**なので、余分なぼけが
    /// 1 段も入らない。
    var jitterInSource: SIMD2<Float> {
        let offset = jitter
        return SIMD2(offset.x / Float(drawnWidth), offset.y / Float(drawnHeight))
    }

    /// 1 枚ぶん進める。
    func advance() { framesScaled += 1 }

    /// ハルトン列の 1 項 (0…1)。
    private static func radicalInverse(_ index: Int, base: Int) -> Float {
        var result: Float = 0
        var fraction = 1 / Float(base)
        var remaining = index
        while remaining > 0 {
            result += Float(remaining % base) * fraction
            remaining /= base
            fraction /= Float(base)
        }
        return result
    }
}
