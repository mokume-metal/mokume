// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 落とした・選んだ動画ファイルを `createVideo` で読み、位置と再生の状態を画面の表示と並べる。
/// **利用者がファイルを渡したときだけ外に触れる、触って確かめるための参照スケッチ** ([#3391])。
///
/// 動画のバイナリはリポジトリに置けず、参照スケッチの中で作ると重い。そこで**資材を利用者が持ち込む形**にして、
/// 何も渡さなければファイルを読まない。書き出しても台帳に載るのは「ファイルを落とす」案内の 1 枚である。
/// 使うのは今ある口 (`play`・`loop`・`pause`・`jump`・`time`・`duration`) だけで、動画の速さや音など
/// 未実装のものを前提にしない。
///
/// ## 起動方法と資材の用意
///
/// 窓を開いて走らせ (`swift run reference-sketches file-and-movie`)、動画ファイル (`.mov`・`.mp4`・`.m4v`) を
/// **窓へ落とす**か、O で**ファイルを選ぶ**。手元に無ければ、自分で撮ったもの・作ったもの、帰属の分かるものを使う。
///
/// ## 操作
///
/// - ファイルを窓へ落とす (`fileDropped(_:)`)・O でファイルを選ぶ (`selectInput(_:)`) — `createVideo` で読む
/// - space — 1 度流す / 止める (`play()` / `pause()`)
/// - L — 繰り返し流す (`loop()`)
/// - ← → — 1 秒戻る・進む (`jump(_:)`)
/// - S — 止めて頭へ戻す (`pause()` と `jump(0)`)
///
/// **作っただけでは流れない。** 読めた直後は最初のコマで止まっていて、space か L で流れ始める。
///
/// ## 正しい見え方
///
/// - 何も渡していない間は、「動画を窓へ落とす」の案内だけが出る
/// - 読めたら、左に映像、右にファイル名・大きさ・長さ・位置 (`time`)・流れ方 (止まっている / 1 度流す /
///   繰り返す / 終わった)。下の帯の印が位置を示し、**流れている間だけ進み、止めると止まる**。映像のコマと
///   位置の表示が揃って動く
/// - ← → で飛ぶと、次のフレームで映像のコマと位置が飛び先になる。止まっていれば、止まったまま飛び先のコマが出る
/// - 1 度だけ流すと、終わりのコマで止まって「終わった」になる。もう一度 space で頭から流れる
/// - 読めないファイル (動画でない・壊れている) を落とすと、**理由が橙の文字で出て**、前に読めていた動画は
///   そのまま残る。読めたら理由は消える
///
/// ## 異常の兆候
///
/// - 何も渡していないのにファイルを読む
/// - 読めないファイルを落としたのに、理由が出ない・前の動画が消える・スケッチが止まる
/// - 流している間、位置が進まない・映像が動かない・止めても進み続ける
///
/// [#3391]: https://github.com/mokume-metal/mokume/issues/3391
final class FileAndMovie: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "file and movie")
    }

    /// 流し方。**自分で覚える** — 動画の口は頼むだけで、いまの流し方を読む口は無い。
    enum Mode {
        case paused, once, looping
    }

    /// 読めた動画。**読めなかったときは前のまま残す。**
    var clip: Movie?
    /// 読めたファイルの名前。
    var clipName = ""
    /// 読めなかった理由。読めたら消す。
    var failure = ""
    /// 頼んだ流し方。
    var mode = Mode.paused
    /// O で選んだパス。次の `draw()` の頭で読む。
    var chosen: String?
    /// 選んでいる最中か。
    var choosing = false

    /// 映像を置く枠。
    private static let frameWidth: Float = 600
    private static let frameHeight: Float = 340

    /// 落とされた。**最初の 1 つだけ**読む。
    func fileDropped(_ paths: [String]) {
        if let first = paths.first { load(first) }
    }

    func keyPressed() {
        switch keyCode {
        case .o:
            guard !choosing else { return }
            choosing = true
            Task {
                chosen = await selectInput("動画ファイルを選ぶ")
                choosing = false
            }
        case .space:
            guard let clip else { return }
            if mode == .paused {
                clip.play()
                mode = .once
            } else {
                clip.pause()
                mode = .paused
            }
        case .l:
            clip?.loop()
            if clip != nil { mode = .looping }
        case .s:
            clip?.pause()
            clip?.jump(0)
            mode = .paused
        case .arrowLeft:
            if let clip { clip.jump(clip.time - 1) }
        case .arrowRight:
            if let clip { clip.jump(clip.time + 1) }
        default:
            break
        }
    }

    /// 読む。読めなければ理由を覚え、前の動画は触らない。
    private func load(_ path: String) {
        do {
            let loaded = try createVideo(path)
            if let clip { detach(clip) }
            clip = loaded
            clipName = Self.name(of: path)
            failure = ""
            mode = .paused
        } catch {
            failure = "\(Self.name(of: path)) を読めなかった: \(error)"
        }
    }

    func draw() {
        if let path = chosen {
            chosen = nil
            load(path)
        }

        background(18, 18, 24)
        noStroke()
        guard let clip else {
            guide()
            return
        }

        // 左: 映像。枠の中へ縦横比を保って置く
        let scale = min(Self.frameWidth / Float(clip.width), Self.frameHeight / Float(clip.height))
        let shownWidth = Float(clip.width) * scale
        let shownHeight = Float(clip.height) * scale
        fill(8, 8, 12)
        rect(24, 24, Self.frameWidth, Self.frameHeight)
        image(clip.image, 24 + (Self.frameWidth - shownWidth) / 2, 24 + (Self.frameHeight - shownHeight) / 2, shownWidth, shownHeight)

        // 右: 名前・大きさ・長さ・位置・流れ方
        let finished = mode == .once && clip.time >= clip.duration - 0.05
        let label: String
        switch mode {
        case .paused: label = "止まっている"
        case .once: label = finished ? "終わった (space でもう一度)" : "1 度流している"
        case .looping: label = "繰り返している"
        }
        fill(230, 237, 255)
        textSize(22)
        text(clipName, 650, 50)
        textSize(18)
        fill(150, 165, 190)
        text("大きさ \(clip.width) × \(clip.height)", 650, 86)
        text("長さ \(String(format: "%.2f", clip.duration)) 秒", 650, 116)
        fill(230, 237, 255)
        textSize(26)
        text("位置 \(String(format: "%.2f", clip.time)) 秒", 650, 170)
        textSize(20)
        fill(mode == .paused || finished ? color(150, 165, 190) : color(232, 170, 92))
        text(label, 650, 206)
        fill(150, 165, 190)
        textSize(16)
        text(clip.isNewFrame ? "新しいコマが届いた" : "同じコマのまま", 650, 240)

        // 下: 位置の帯。映像と同じ位置を指す
        let fraction = constrain(clip.time / max(clip.duration, 0.001), 0, 1)
        fill(40, 40, 48)
        rect(24, 400, width - 48, 12)
        fill(232, 170, 92)
        rect(24, 400, (width - 48) * fraction, 12)
        fill(255)
        rect(24 + (width - 48) * fraction - 2, 392, 4, 28)

        status()
    }

    /// 何も読めていないときの案内。**触らずに書き出した絵 (台帳の 1 枚) はこれになる。**
    private func guide() {
        noFill()
        stroke(76, 87, 107)
        strokeWeight(3)
        rect(160, 130, width - 320, 260)
        noStroke()
        fill(230, 237, 255)
        textSize(28)
        text("動画を窓へ落とす", 380, 250)
        textSize(20)
        fill(150, 165, 190)
        text("または O でファイルを選ぶ", 358, 290)
        text("space 流す  L 繰り返す  ← → 1 秒動かす  S 頭へ", 262, 330)
        status()
    }

    /// 選んでいる最中と、読めなかった理由。どちらも無ければ何も出さない。
    private func status() {
        textSize(18)
        if choosing {
            fill(242, 217, 89)
            text("選んでいる…", 24, height - 24)
        }
        if !failure.isEmpty {
            // 理由にはパスが入って長いので、枠の中で折り返す
            fill(242, 140, 64)
            textSize(16)
            text(failure, 24, height - 90, width - 48, 56)
        }
    }

    /// パスの最後の要素。
    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
