// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 描画の土台で起こりうる失敗。
///
/// 起こりうる失敗が列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
///
/// **大半は「環境かリソースが足りない」形だが、それに限らない。** 頼んだ値が通らないもの
/// (``invalidSize(width:height:)`` / ``invalidPixelDensity(_:)``) と、呼ぶ順序が誤っているもの
/// (``commandsAlreadyOpen``) も同じ型で運ぶ。呼び出し側から見ればどれも `try` した先で
/// 起きたことで、運び方を分けても受け取る場所が増えるだけだからである ([#792])。
///
/// **区別を持つのは ``description`` のほうである。** 資源が足りないなら「走ったままの
/// スケッチを閉じてから試す」、呼び方が誤っているなら「呼ぶ場所を直す」と、次にすることが
/// 文面で分かれる — そこが揃っていないと、踏んだ人を間違った方向へ送る。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [#792]: https://github.com/mokume-metal/mokume/issues/792
public enum RenderFailure: Error, Equatable, Sendable {
    /// GPU が見つからない (仮想環境・GPU を持たない実行環境)。
    case deviceUnavailable

    /// コマンドの発行口を作れない。
    case commandQueueUnavailable

    /// コマンドの置き場を作れない。
    case commandAllocatorUnavailable

    /// コマンドを 1 本作れない。
    case commandBufferUnavailable

    /// コマンドを組み立てている最中に、それを許さない口を呼んだ。**呼び出し順の誤り**で、
    /// 資源は足りている。
    ///
    /// 許さないのは、その口が自分のコマンドをもう 1 本開くからである。開いたまま置き場の
    /// 環を 1 周すると同じ置き場を二重に開くことになり、検証層が止める (層が無ければ
    /// 未定義)。いま該当するのは `RenderDevice.makeClearedTexture(descriptor:)` の 1 つ。
    case commandsAlreadyOpen

    /// 常駐させる集合を作れない。
    case residencySetUnavailable(reason: String)

    /// GPU の完了を待つための合図を作れない。
    case synchronizationUnavailable

    /// 指定した大きさの描画先を確保できない。
    case textureUnavailable(width: Int, height: Int)

    /// 読み出し先を確保できない。
    case bufferUnavailable(byteCount: Int)

    /// コマンドを書き込む口を作れない。
    case encoderUnavailable

    /// GPU の完了を待ったが、制限時間内に終わらなかった。
    ///
    /// 待ち時間の上限を秒で持つのは、検証が壁時計の絶対値ではなくこの値そのものを
    /// 物差しにできるようにするため。
    case timedOut(seconds: Int)

    /// 描画先の大きさが正しくない (幅・高さは 1 以上、面の一辺の上限以下でなければ
    /// ならない)。上限そのものは ``description`` が名乗る。
    ///
    /// **上限も同じ case で運ぶ。** 呼び出し側がすることは下限を割ったときと同じ
    /// (頼む大きさを直す) で、分けても選び分ける先が無い ([#885])。
    ///
    /// [#885]: https://github.com/mokume-metal/mokume/issues/885
    case invalidSize(width: Int, height: Int)

    /// 描く細かさが正しくない (0 より大きく 1 以下でなければならない)。
    ///
    /// 1 を超える指定 — 出すより細かく描いて縮める — は引き受けない。拡大器が
    /// 縮小を扱わないうえ、要求も出ていないためである。
    case invalidPixelDensity(Float)

    /// 同梱しているはずのシェーダの原文が見つからない。
    case shaderSourceMissing(name: String)

    /// シェーダを組み立てられない。
    case shaderCompilationFailed(name: String, reason: String)

    /// シェーダを組み立てる口を作れない。
    case shaderCompilerUnavailable

    /// 描画のパイプラインを作れない。
    case pipelineUnavailable(reason: String)

    /// 資源を渡すテーブルを作れない。
    case argumentTableUnavailable(reason: String)

    /// テクスチャの読み取り方を作れない。
    case samplerUnavailable
}

extension RenderFailure: CustomStringConvertible {
    /// 人が読む文面。
    ///
    /// **どの失敗にも「次に何をすればよいか」を書く。** 起動できなかったときに出る行は
    /// 利用者が最初に見る失敗で、しかも**配った先で出る** — 読む人は組み上げ方を知らない
    /// ことがあるので、状態の報告だけでは足りない ([#527])。道具の側 (`CommandFailure`) が
    /// 既に持っている規範を、ライブラリの側にも通す。
    ///
    /// **内部の名前をそのまま出さない。** case の綴りは実装の都合で決まっていて、読む人が
    /// 次にすることを決める助けにならない。準拠しているので `\(failure)` と書いた場所も
    /// この文面になる — 内部の名前が出る経路が残らない。
    ///
    /// **姉妹型と同じ形で公開する。** ``ImageFailure`` / ``ModelFailure`` / ``ShaderFailure``
    /// はいずれも `CustomStringConvertible` で人向けの文面を出しており、ここだけ internal
    /// だったせいで、アンブレラしか見えない場所 (参照スケッチ) が同じ文面を出せなかった
    /// ([#600])。実需ではなく**既にある規範が要求する一貫性の欠け**を埋めるもの
    /// ([ADR-0022] 決定 6 の 2 行目)。
    ///
    /// 走っている最中の警告は多行を流せないので、そちらは ``headline`` を使う。
    ///
    /// [#527]: https://github.com/mokume-metal/mokume/issues/527
    /// [#600]: https://github.com/mokume-metal/mokume/issues/600
    /// [ADR-0022]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0022-production-track.md
    public var description: String {
        switch self {
        case .deviceUnavailable:
            """
            GPU が見つからない。
            mokume が走るのは GPU を持つ Mac の上だけで、仮想環境では動かない。
            """
        case .commandQueueUnavailable:
            Self.exhausted("コマンドの発行口")
        case .commandAllocatorUnavailable:
            Self.exhausted("コマンドの置き場")
        case .commandBufferUnavailable:
            Self.exhausted("コマンドを運ぶ 1 本")
        case .commandsAlreadyOpen:
            // **資源枯渇の共通文面 (`Self.exhausted`) へ寄せない。** あちらは「走ったままの
            // スケッチを閉じてから試す」で終わるが、ここで閉じても何も変わらない (#792)
            """
            コマンドを組み立てている最中に、塗った面を作ろうとした。
            資源の不足ではなく呼び出し順の誤りで、面を作るのは組み立てを始める前か、
            投入し終えたあとにする。
            """
        case .residencySetUnavailable(let reason):
            Self.exhausted("常駐させる集合", reason: reason)
        case .synchronizationUnavailable:
            Self.exhausted("GPU の完了を待つ合図")
        case .encoderUnavailable:
            Self.exhausted("コマンドを書き込む口")
        case .textureUnavailable(let width, let height):
            """
            \(width)×\(height) の描画先を確保できない。
            GPU のメモリが足りていない — 窓を小さくするか、描く細かさを下げる。
            """
        case .bufferUnavailable(let byteCount):
            """
            \(byteCount) バイトの読み出し先を確保できない。
            GPU のメモリが足りていない — 一度に扱う数を減らす。
            """
        case .timedOut(let seconds):
            """
            GPU の完了を \(seconds) 秒待ったが、終わらなかった。
            1 フレームで描く量が多すぎる — 描く数を減らすか、シェーダを軽くする。
            """
        case .invalidSize(let width, let height):
            """
            描画先の大きさが正しくない: \(width)×\(height)
            幅・高さはどちらも 1 以上 \(RenderDevice.maxTextureSide) 以下にする。
            """
        case .invalidPixelDensity(let density):
            """
            描く細かさが正しくない: \(density)
            0 より大きく 1 以下にする (1 が出すとおりの細かさで、小さいほど粗く描いて拡大する)。
            """
        case .shaderSourceMissing(let name):
            """
            同梱しているはずのシェーダの原文が見つからない: \(name)
            束ねて配ったときにいちばん起きやすい失敗で、包みの中に資源が入っていないと
            こうなる — \(ModuleResources.bundleName).bundle が <名前>.app/Contents/Resources/ か
            <名前>.app/ の直下にあるか確かめる。無ければ束ね直す。
            """
        case .shaderCompilationFailed(let name, let reason):
            """
            シェーダを組み立てられない: \(name)
            \(reason)
            上の理由が指す箇所を、書いた断片の側で直す。
            """
        case .shaderCompilerUnavailable:
            """
            シェーダを組み立てる口を作れない。
            この機械の Metal が要求に足りていない — macOS の版を確かめる。
            """
        case .pipelineUnavailable(let reason):
            """
            描画のパイプラインを作れない: \(reason)
            シェーダの入口の名前と、渡している資源の並びが合っているか確かめる。
            """
        case .argumentTableUnavailable(let reason):
            """
            資源を渡すテーブルを作れない: \(reason)
            一度に渡す資源の数が多すぎないか確かめる。
            """
        case .samplerUnavailable:
            Self.exhausted("テクスチャの読み取り方")
        }
    }

    /// 走っている最中に出す 1 行 (``description`` の先頭行 = 何が足りないか)。
    ///
    /// **`Diagnostics.warn` は 1 行しか流せない。** 宣言自身が「ライブラリからの注意を
    /// 1 行、標準エラーへ書く」と名乗っており、毎フレーム起こりうる失敗に多行を流すと
    /// 本当に読むべき行が埋まる (`SketchApplication.noteFrameFailure` のコメント)。
    ///
    /// **1 行に削るのは、人が端末で読む経路だけである** ([#600])。観測レポートの `warnings`
    /// は JSON の配列なので行数の制約が無く、読み手も機械なので全文 (`\(failure)`) を載せる
    /// — 組み立て直しの失敗はコンパイラの言葉が 2 行目に入るので、そこを削ると打つ手が
    /// 消える。起動の失敗も全文を出す (そこで終わりなので、次にすることまで要る)。
    ///
    /// [#600]: https://github.com/mokume-metal/mokume/issues/600
    nonisolated var headline: String {
        String(description.prefix { $0 != "\n" })
    }

    /// GPU の資源を用意できなかったときの文面。
    ///
    /// 用意できない口はいくつもあるが、**読む人が次にすることは同じ**なので 1 箇所で組む。
    /// 何を用意できなかったかは名指しする — 同じ文面が並ぶと、どこで止まったか分からなくなる。
    private nonisolated static func exhausted(_ what: String, reason: String? = nil) -> String {
        let head = reason.map { "\(what)を用意できない: \($0)" } ?? "\(what)を用意できない。"
        return """
            \(head)
            GPU の資源が尽きている疑いがある — 走ったままのスケッチを閉じてから試し直す。
            """
    }
}
