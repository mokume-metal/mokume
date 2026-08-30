// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 描画の土台で起こりうる失敗。
///
/// 起こりうる失敗が列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
/// どれも「環境かリソースが足りない」形の失敗で、呼び出し側の引数の誤りではない。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
public enum RenderFailure: Error, Equatable, Sendable {
    /// GPU が見つからない (仮想環境・GPU を持たない実行環境)。
    case deviceUnavailable

    /// コマンドの発行口を作れない。
    case commandQueueUnavailable

    /// コマンドの置き場を作れない。
    case commandAllocatorUnavailable

    /// コマンドを 1 本作れない。
    case commandBufferUnavailable

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

    /// 描画先の大きさが正しくない (幅・高さは 1 以上でなければならない)。
    case invalidSize(width: Int, height: Int)

    /// 描く細かさが正しくない (0 より大きく 1 以下でなければならない)。
    ///
    /// 1 を超える指定 — 出すより細かく描いて縮める — は引き受けない。拡大器が
    /// 縮小を扱わないうえ、要求も出ていないためである。
    case invalidPixelDensity(Float)

    /// 拡大の段を組み立てられない。
    case upscalerUnavailable(reason: String)

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

    /// 表示できる面を用意できない。
    case displaySurfaceUnavailable
}

extension RenderFailure {
    /// 人が読む文面。
    ///
    /// **どの失敗にも「次に何をすればよいか」を書く。** 起動できなかったときに出る行は
    /// 利用者が最初に見る失敗で、しかも**配った先で出る** — 読む人は組み上げ方を知らない
    /// ことがあるので、状態の報告だけでは足りない ([#527])。道具の側 (`CommandFailure`) が
    /// 既に持っている規範を、ライブラリの側にも通す。
    ///
    /// **内部の名前をそのまま出さない。** case の綴りは実装の都合で決まっていて、読む人が
    /// 次にすることを決める助けにならない。
    ///
    /// 公開していないのは、外から読む必要がまだ出ていないため (ADR-0001 原則 4)。利用者の
    /// catch で要ると分かった時点で広げる。
    ///
    /// [#527]: https://github.com/mokume-metal/mokume/issues/527
    nonisolated var message: String {
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
            幅・高さはどちらも 1 以上にする。
            """
        case .invalidPixelDensity(let density):
            """
            描く細かさが正しくない: \(density)
            0 より大きく 1 以下にする (1 が出すとおりの細かさで、小さいほど粗く描いて拡大する)。
            """
        case .upscalerUnavailable(let reason):
            """
            拡大の段を組み立てられない: \(reason)
            描く細かさを 1 にすると、拡大の段そのものを通らなくなる。
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
        case .displaySurfaceUnavailable:
            """
            表示できる面を用意できない。
            窓が閉じられたか、画面から外れている — 窓を出し直す。
            """
        }
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
