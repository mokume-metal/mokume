// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 足場を走って跳ぶ横スクロール。**ゲーム層 `MokumeGame` の 3 つの API で書けることを示す** (#2606 の作例)。
///
/// タイトルで return を押すと始まる。← → で走り、space で跳ぶ (足場に立っているときだけ)。道中のコインに
/// 触れるとスコアが 10 増える。右端の旗に触れるか、穴に 3 回落ちると結果の画面になり、return でタイトルへ戻る。
///
/// 使う API はゲーム層の 3 つと、段 1 の値と問い (#2598 の作例と同じ) だけである:
///
/// - 場面の切り替え — `Scene` (`change(to:)` は次のフレームの頭で効く。入った最初のフレームは `justEntered`)
/// - 重力・接地・めり込みの解消 — `ArcadeBody` (`step(gravity:solids:)` を `draw()` から 1 回。立っているかは `isOnFloor`)
/// - カメラの追従 — `Camera2D` (`follow(_:)` で追い、面の端で止まる。`translate(-camera.x, 0)` で世界の座標へ)
///
/// **場面の切り替え・重力の積み上げ・接地の判定・めり込みの解消・カメラの追従を、ここでは書かない。**
/// 書くのは入力から速さを決めることと、コイン・旗・落下の判定 (`Rect` の `intersects` と位置の比較) だけ。
///
/// ## 面は文字列の格子で書く
///
/// 面は `level` の文字列で、1 文字が 30 × 30 の 1 マス。`#` が足場と壁・`o` がコイン・`F` が旗・`P` が
/// 始まりの位置。64 マスで、画面 (480) の 4 倍の幅 (1920) になる。資材のファイルは置かない。
///
/// ## フレームの時計で回す
///
/// `clock: .frames` なので、`draw()` 1 回がちょうど 1/60 秒で、`ArcadeBody` の 1 歩の刻みも毎回同じになる。
/// **同じ入力を流せば、同じフレームの位置とスコアは何度走らせても同じになる。**
///
/// ## 音は使い回す
///
/// 跳んだ音とコインの音は合成音で鳴らす。**音源と包絡は `setup()` で 1 つずつ作り、鳴らすたびに包絡を
/// かけ直す** (鳴らすたびに作ると 64 個の上限を使い切って黙る — #2763)。
///
/// ## 外から確かめる
///
/// `expose` で `scene`・`playerX`・`playerY`・`grounded`・`cameraX`・`score`・`falls` を差し出している。
/// `mokume watch` と MCP の `input` で return を押し、→ を押したまま `observe` でフレームごとの値を読むと、
/// `playerX` が画面の中央 (240) を越えたところから `cameraX` が追い始める。
///
/// 確認: `swift run reference-sketches jump-and-scroll` でウィンドウを開く。return で始め、→ で走ると
/// 画面の中央からカメラが追うこと、壁 (2 マスの高さ) に → を押し続けるとめり込まずに止まること、space で
/// 跳び越えられること、空中でもう一度 space を押しても高く跳ばないことを見る。コインに触れると SCORE が 10
/// 増え、穴に落ちると FALLS が 1 増えて始まりの位置へ戻る。3 回落ちるか旗に触れると結果の画面になり、return で
/// タイトルへ戻る。`--render /tmp/mokume-frames --frames 45` はタイトルの画面まで (入力は送らない)。
///
final class JumpAndScroll: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 480, height: 270, title: "jump and scroll", clock: .frames)
    }

    /// 場面。`expose` へは `rawValue` で渡す。
    enum Screen: String { case title, game, result }

    /// 面。1 文字が 1 マス (`#` 足場・`o` コイン・`F` 旗・`P` 始まりの位置)。
    static let level = [
        "#                                                              #",
        "#                                                              #",
        "#                                                              #",
        "#                                                              #",
        "#                                                              #",
        "#                        o o                 o o               #",
        "#       #           o    ####          o    #####              #",
        "# P     #  o o o                #                   o o     F  #",
        "####################  ################  ########################",
    ]
    static let tile: Float = 30
    static let worldWidth = Float(level[0].count) * tile

    /// 走る速さ・跳ぶ速さ・重力 (1 秒あたり)。跳べる高さは 420² / (2 × 1200) ≈ 74 で、2 マス (60) の壁を越える。
    static let runSpeed: Float = 160
    static let jumpSpeed: Float = 420
    static let gravity = Vector2(0, 1200)
    static let maxFalls = 3

    var scene = Scene(starting: Screen.title)
    /// このフレームで描いている場面。`draw()` の頭で `scene.current` を写す (切り替えを頼んでも、
    /// そのフレームの終わりまで変わらない)。
    var screen = Screen.title
    var camera = Camera2D(worldWidth: JumpAndScroll.worldWidth)
    var player = ArcadeBody(JumpAndScroll.start)
    var solids: [Rect] = []
    var coins: [Circle] = []
    var flag = Rect(left: 0, top: 0, width: 0, height: 0)
    var score = 0
    var falls = 0
    /// 旗に触れて終えたか (結果の画面の文言を分ける)。
    var reachedGoal = false

    var tone: TriOsc?
    var envelope: Env?

    func setup() {
        tone = createTriOsc()
        tone?.amp(0.3)
        envelope = createEnv()
        layLevel()
    }

    func draw() {
        screen = scene.current
        switch screen {
        case .title:
            if keyboard.justPressed(.enter) { scene.change(to: .game) }  // 効くのは次のフレームの頭
        case .game:
            if scene.justEntered { startOver() }  // 入った最初のフレームだけ
            play()
        case .result:
            if keyboard.justPressed(.enter) { scene.change(to: .title) }
        }
        camera.follow(player.rect.center)

        expose("scene", screen.rawValue)
        expose("playerX", player.rect.left)
        expose("playerY", player.rect.top)
        expose("grounded", player.isOnFloor)
        expose("cameraX", camera.x)
        expose("score", score)
        expose("falls", falls)

        drawWorld()
        drawHUD()
    }

    // MARK: - 面を組む

    /// 始まりの位置 (`P` のマス) に立つ体の矩形。幅 18・高さ 26 で、マスの下端に足を付ける。
    static let start: Rect = {
        for (row, line) in level.enumerated() {
            if let col = Array(line).firstIndex(of: "P") {
                return Rect(
                    left: Float(col) * tile + (tile - 18) / 2, top: Float(row + 1) * tile - 26, width: 18, height: 26)
            }
        }
        return Rect(left: tile, top: 0, width: 18, height: 26)
    }()

    /// 格子の文字列から、足場・コイン・旗を組む。
    func layLevel() {
        solids = []
        coins = []
        for (row, line) in Self.level.enumerated() {
            for (col, mark) in line.enumerated() {
                let cell = Rect(left: Float(col) * Self.tile, top: Float(row) * Self.tile, width: Self.tile, height: Self.tile)
                switch mark {
                case "#": solids.append(cell)
                case "o": coins.append(Circle(center: cell.center, radius: 7))
                case "F": flag = Rect(left: cell.left + 12, top: cell.top - Self.tile, width: 6, height: Self.tile * 2)
                default: break
                }
            }
        }
    }

    /// 最初の状態へ戻す (ゲームの場面に入った最初のフレーム)。
    func startOver() {
        score = 0
        falls = 0
        reachedGoal = false
        layLevel()
        player = ArcadeBody(Self.start)
    }

    // MARK: - 1 フレームを進める: 入力で速さを決め、1 歩は ArcadeBody に任せる

    func play() {
        let right: Float = keyboard.isPressed(.arrowRight) ? 1 : 0
        let left: Float = keyboard.isPressed(.arrowLeft) ? 1 : 0
        player.velocity.x = (right - left) * Self.runSpeed
        // 跳べるのは立っているときだけ。空中で押しても速さは足さない
        if keyboard.justPressed(.space), player.isOnFloor {
            player.velocity.y = -Self.jumpSpeed
            beep(440)
        }
        player.step(gravity: Self.gravity, solids: solids)  // 呼ぶ 1 回で 1 歩

        let picked = coins.filter { player.rect.intersects($0) }
        if !picked.isEmpty {
            coins.removeAll { player.rect.intersects($0) }
            score += 10 * picked.count
            beep(880)
        }
        if player.rect.intersects(flag) {
            reachedGoal = true
            scene.change(to: .result)
        } else if player.rect.top > height {
            falls += 1
            if falls >= Self.maxFalls {
                scene.change(to: .result)
            } else {
                player = ArcadeBody(Self.start)
            }
        }
    }

    /// 鳴らす。同じ音源に包絡をかけ直すので、音源は増えない。
    func beep(_ frequency: Float) {
        guard let tone, let envelope else { return }
        tone.freq(frequency)
        envelope.play(tone, 0.002, 0.03, 0.5, 0.08)
    }

    // MARK: - 描く: 世界はカメラの分だけずらし、文字は画面に固定する

    func drawWorld() {
        background(120, 180, 230)
        noStroke()
        push {
            translate(-camera.x, 0)  // ここから世界の座標
            fill(90, 70, 50)
            for solid in solids { solid.draw() }
            fill(255, 214, 64)
            for coin in coins { coin.draw() }
            fill(240)
            flag.draw()
            fill(229, 57, 53)
            Rect(left: flag.right, top: flag.top, width: 20, height: 14).draw()
            fill(30, 40, 90)
            player.rect.draw()
        }
    }

    func drawHUD() {
        fill(255)
        textSize(14)
        text("SCORE \(score)", 16, 24)
        text("FALLS \(falls)/\(Self.maxFalls)", width - 104, 24)
        textSize(18)
        switch screen {
        case .title:
            text("JUMP AND SCROLL  PRESS RETURN", 96, 110)
        case .game:
            break
        case .result:
            text(reachedGoal ? "GOAL!  PRESS RETURN" : "GAME OVER  PRESS RETURN", 120, 110)
        }
    }
}
