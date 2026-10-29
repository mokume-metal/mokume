// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 落とした・選んだ音声ファイルを `loadSound` で読み、再生と解析の値を並べる。
/// **利用者がファイルを渡したときだけ外に触れる、触って確かめるための参照スケッチ** ([#3390])。
///
/// 音声の資材はリポジトリに置けない。そこで**資材を利用者が持ち込む形**にして、何も渡さなければ
/// ファイルを読まず・音も鳴らさない。書き出しても台帳に載るのは「ファイルを落とす」案内の 1 枚である。
/// 鳴らさずに解析する形は `SoundAndLevel` (`createAudioIn(samples:)`) が示している — ここは**ファイルを読んで
/// 再生する**ことに絞る。
///
/// ## 起動方法と資材の用意
///
/// 窓を開いて走らせ (`swift run reference-sketches file-and-sound`)、音声ファイル (WAV・AIFF・MP3・M4A など)
/// を**窓へ落とす**か、O で**ファイルを選ぶ**。手元に無ければ、自分で作った短い音か、帰属の分かるものを使う。
///
/// ## 操作
///
/// - ファイルを窓へ落とす (`fileDropped(_:)`) — `loadSound` で読む
/// - O でファイルを選ぶ (`selectInput(_:)`) — `requestSound` で読む
/// - space — 鳴らす / 止める (`play()` / `pause()`)
/// - L — 頭から繰り返して鳴らす (`loop()`)
/// - ← → — 1 秒戻る・進む (`jump(_:)`)
/// - S — 止めて頭へ戻す (`stop()`)
///
/// **読むだけなら音は鳴らない** — 鳴らすのは space か L を押したときだけで、機材へ鳴らす操作はそこに限る。
/// 読んだだけの間も、ファイル名・長さ・標本の数は画面に出る。解析の値 (`rms`・`peak`・`level`・帯域) は
/// 鳴っている間のものなので、止まっている間は 0 に落ちる。
///
/// ## 正しい見え方
///
/// - 何も渡していない間は、「音声ファイルを窓へ落とす」の案内だけが出る
/// - 読めたら、上にファイル名・長さ・位置と再生の状態。位置の帯が鳴っている間だけ進み、止めると止まる
/// - 鳴っている間、左の 2 本が `rms` と `level`、白い横線が `peak`、右の棒が帯域ごとの `spectrumLevels`、
///   下の線が `waveform` で、音に合わせて動く
/// - 読めないファイル (音声でない・壊れている) を落とすと、**理由が橙の文字で出て**、前に読めていた音は
///   そのまま鳴り続ける。読めたら理由は消える
///
/// ## 異常の兆候
///
/// - 何も渡していないのにファイルを読む・音が鳴る
/// - 読めないファイルを落としたのに、理由が出ない・前の音が止まる・スケッチが止まる
/// - 鳴らしているのに位置が進まない・止めても進み続ける
///
/// O で選んだファイルは、ダイアログの結果が届いた `Task` の中で `requestSound` で読む (そこでは同期の
/// `loadSound` は呼べない)。落とす経路は入力のコールバックの中で `loadSound` で読む。どちらも、読み込みが
/// `draw()` の中にあるという警告は出ない ([#3398])。
///
/// [#3390]: https://github.com/mokume-metal/mokume/issues/3390
/// [#3398]: https://github.com/mokume-metal/mokume/issues/3398
final class FileAndSound: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "file and sound")
    }

    /// 読めた音。**読めなかったときは前のまま残す。**
    var song: SoundFile?
    /// 読めたファイルの名前。
    var songName = ""
    /// 読めなかった理由。読めたら消す。
    var failure = ""
    /// 選んでいる最中か。
    var choosing = false

    /// 帯域を何本描くか。
    private let bands = 64

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
                defer { choosing = false }
                guard let path = await selectInput("音声ファイルを選ぶ") else { return }
                await request(path)
            }
        case .space:
            guard let song else { return }
            if song.isPlaying { song.pause() } else { song.play() }
        case .l:
            song?.loop()
        case .s:
            song?.stop()
        case .arrowLeft:
            if let song { song.jump(song.position - 1) }
        case .arrowRight:
            if let song { song.jump(song.position + 1) }
        default:
            break
        }
    }

    /// 入力のコールバックの中で読む。読めなければ理由を覚え、前の音は触らない。
    private func load(_ path: String) {
        do {
            replace(with: try loadSound(path), from: path)
        } catch {
            failure = "\(Self.name(of: path)) を読めなかった: \(error)"
        }
    }

    /// `Task` の中で読む。`selectInput` の結果は `Task` に届き、そこでは `loadSound` は呼べない。
    private func request(_ path: String) async {
        do {
            replace(with: try await requestSound(path), from: path)
        } catch {
            failure = "\(Self.name(of: path)) を読めなかった: \(error)"
        }
    }

    /// 読めた音に差し替える。前の音は止めて外す。
    private func replace(with loaded: SoundFile, from path: String) {
        if let song {
            song.stop()
            detach(song)
        }
        song = loaded
        songName = Self.name(of: path)
        failure = ""
    }

    func draw() {
        background(18, 18, 24)
        noStroke()
        guard let song else {
            guide()
            return
        }

        // 上: 読めたファイルと再生の状態
        fill(230, 237, 255)
        textSize(24)
        text(songName, 24, 44)
        textSize(18)
        fill(150, 165, 190)
        text(
            "長さ \(String(format: "%.2f", song.duration)) 秒   位置 \(String(format: "%.2f", song.position)) 秒   "
                + (song.isPlaying ? "鳴っている" : "止まっている"),
            24, 76)
        // 位置の帯
        fill(40, 40, 48)
        rect(24, 92, width - 48, 10)
        fill(232, 170, 92)
        rect(24, 92, (width - 48) * constrain(song.position / max(song.duration, 0.001), 0, 1), 10)

        // 左: rms (生) と level (0〜1 に写した値)。白い横線は peak
        meter(x: 60, value: song.rms, red: 120, green: 160, blue: 220)
        meter(x: 100, value: song.level, red: 232, green: 170, blue: 92)
        fill(255)
        rect(52, 440 - constrain(song.peak, 0, 1) * 310 - 1, 40, 2)

        // 右: 帯域ごとの大きさ
        let levels = song.spectrumLevels
        for band in 1...bands {
            let height = levels[band] * 310
            fill(lerp(120, 232, Float(band) / Float(bands)), 160, lerp(220, 92, Float(band) / Float(bands)))
            rect(200 + Float(band - 1) * 11, 440 - height, 9, height)
        }

        // 下: 区間の波形
        let wave = song.waveform
        if wave.count > 1 {
            noFill()
            stroke(120, 230, 160)
            strokeWeight(1.5)
            beginShape()
            for (index, value) in wave.enumerated() {
                vertex(24 + Float(index) / Float(wave.count - 1) * (width - 48), 526 + constrain(value, -1, 1) * 12)
            }
            endShape()
            noStroke()
        }

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
        text("音声ファイルを窓へ落とす", 330, 250)
        textSize(20)
        fill(150, 165, 190)
        text("または O でファイルを選ぶ", 358, 290)
        text("space 鳴らす  L 繰り返す  ← → 1 秒動かす  S 頭へ", 250, 330)
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

    /// 縦の目盛り 1 本。下から `value` (0〜1) の高さまで塗る。
    private func meter(x: Float, value: Float, red: Float, green: Float, blue: Float) {
        fill(40, 40, 48)
        rect(x, 130, 24, 310)
        fill(red, green, blue)
        let height = constrain(value, 0, 1) * 310
        rect(x, 440 - height, 24, height)
    }

    /// パスの最後の要素。
    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
