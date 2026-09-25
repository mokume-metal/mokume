---
name: visual-evidence
description: 描画結果・動きが変わる変更を PR / Issue に記録するとき、スケッチの絵や窓の様子を上げて URL を得る。本線は Gyazo で、落ちていれば GitHub の添付へ退避する。撮る経路・宛先ごとの形式・出所の残し方を扱う。Use when attaching visual evidence to a pull request or issue, when a drawing or motion change needs before/after images, when capturing an animated WebP or GIF, when Gyazo is unavailable or its URLs return 404, or when embedding images in docs.
allowed-tools: "mcp__gyazo-mac__gyazo_list_capturable_windows"
---

<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 視覚証跡を残す

**何を載せるかの規律は AGENTS.md 「描画に影響する変更」が正典**で、ここは手順だけを持つ。

手順が要るのは、証跡がこのリポジトリでは添え物ではないからである。CI は描画を走らせられない
([#180](https://github.com/mokume-metal/mokume/issues/180)) ので、**緑は「描けている」を意味しない**。
PR に貼られた絵が描画の唯一の検証記録になり、squash merge でブランチが消えた後には足せない。

> **人がこれを読んでいるなら、たいていここは要らない。** Issue / PR の入力欄へ画像を落とせば
> GitHub が保管して URL を返す — アカウントもトークンも要らず、そちらの方が早い。
> この文書が扱うのは**エージェントの経路**である。

**上げ先は 2 つある。本線は Gyazo で、落ちていれば GitHub の添付へ退避する** (「上げる」節)。

退避路があるのは、上げ先が 1 本だと**そこが落ちた瞬間に描画の PR を出せなくなる**からである
([#1294](https://github.com/mokume-metal/mokume/issues/1294) で 178 本が一斉に 404 になった)。
GitHub には添付の API が無いが、**ブラウザを操作できるセッションなら人間と同じ経路を通せる**
([#1306](https://github.com/mokume-metal/mokume/issues/1306) で実測)。

## 撮る経路は 2 つ

| | 撮るもの | 撮り方 |
| --- | --- | --- |
| **A** (既定) | mokume が描いた絵 | 観測 |
| **B** | 窓・GUI・操作そのもの | 画面の撮影 |

A を既定にするのは理由が 3 つ重なるため — 同じ条件で撮り直せる / 他アプリの映り込みが構造的に無い /
窓の位置や画面構成に依存しない。**B は「描画結果ではなく画面そのものを見せたいとき」に限る。**

**撮影と送信は分ける。** Gyazo の MCP には撮って即座に上げる道具があるが、使わない。手元に落として
から上げれば、外部サービスへ送る前に写り込みを検められる。MCP から取るのは窓の一覧だけで、
`allowed-tools` にそれしか載せていないのはこのためである。

## A. スケッチの絵を撮る

走らせてから観測する。**区画を作るのが先、走らせるのが後**である。

```bash
mkdir -p <スケッチの場所>/.mokume/observe    # 起動より先に作る
swift run mokume-cli watch <スケッチの場所>  # 窓が出る
swift run mokume-cli mcp <スケッチの場所>    # エージェントの窓口を立てる
```

> **順序を逆にすると撮れない。** 観測は**起動の瞬間に区画があるときだけ**有効になる
> (`FrameObserver.makeIfEnabled`)。後から作っても、走っているスケッチは拾わない。
> 踏んだときは窓口が「区画はこの呼び出しで作ったので、**起動し直してください**」と返すので、
> **区画は作り直さず、走らせているスケッチを立ち上げ直す** ([#227](https://github.com/mokume-metal/mokume/issues/227))。

窓口の `observe` が返すのは、絵の場所と内訳 (フレーム番号・時刻・大きさ・絵の要約・走らせている
重さ・スケッチが差し出した値・**版の刻印**)。この内訳がそのまま出所の記録になるので、捨てずに取っておく。

> **版の刻印 (`stamp`) が入るのは `watch` の経路だけである。** 刻印を渡すのは作り直して差し替える側
> (`Sources/MokumeCLI/WatchSession.swift`) で、`run` で起こしたスケッチには渡らない — 応答から
> `stamp` が**黙って落ちる** (`Schemas/observe-report.schema.json` でも optional)。出所を刻印で
> 確かめたいなら `watch` で起こす。`run` で撮ったものの出所は、刻印ではなく**撮った本人の記録**
> (どの版を組んだか) しか名乗れない ([#1091](https://github.com/mokume-metal/mokume/issues/1091))。

窓口を立てずに区画へ直接置いてもよい。`.mokume/observe/request.json` へ `{"id": "<毎回変える>"}` を
原子的に置き、`.mokume/observe/report.json` の `id` が一致するまで待つ (仕様は
`Schemas/observe-request.schema.json`、置き方と待ち方の実装は `scripts/observe_lib.py`)。

### 動きも A で撮る

**識別子を変えながら要求を置き、`report.json` の `id` が一致したら `image` が指す絵を退避する** —
これを繰り返せば連番がそのまま手に入る。B のように録画から起こす必要は無い。要求に `scale` を
添えると書き出しの時点で縮むので、束ねる前の縮小も要らない。

**リポジトリの根から打つ** (`scripts/observe_lib.py` を読むため)。

```bash
python3 - <スケッチの場所>/.mokume/observe frames 70 0.5 <<'CAPTURE'
import json, pathlib, shutil, sys, time

sys.path.insert(0, "scripts")
from observe_lib import answered, place          # 置き方と待ち方の正典はこれ 1 つ

facet, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
rounds, scale = int(sys.argv[3]), float(sys.argv[4])
out.mkdir(parents=True, exist_ok=True)
previous, timing = None, []

for index in range(1, rounds + 1):
    identifier = f"f{index:04d}"
    place(facet, {"id": identifier, "scale": scale})

    name, taken = f"f.{index:04d}.png", None
    report = answered(facet, identifier, 1.5)     # 壁時計ではなく識別子の一致で完了を知る
    if report and report.get("image"):
        taken = shutil.copy(facet / report["image"], out / name)

    if taken is None and previous:                # 返らなかったら直前の絵を置く
        shutil.copy(previous, out / name)
    previous = taken or previous
    timing.append({"file": name, "at": time.time()})  # 何時に採れたか = その絵が出ていた長さ

(out / "timing.json").write_text(json.dumps(timing))
CAPTURE
```

**置き方と待ち方をここに写さない** ([#817](https://github.com/mokume-metal/mokume/issues/817))。
実装は `scripts/observe_lib.py` の 1 つで、`scripts/check-observation-roundtrip.sh` と
`scripts/measure-frame-rate.sh` も同じものを読む — 以前はこの 3 か所と文章の 4 通りに散っており、
ADR-0018 決定 3 の正典がどれなのか誰にも分からなかった。**形式の正典は `Schemas/` の
`observe-request` / `observe-report`** である (絵のファイル名も応答の `image` が名乗る — 決め打ちしない)。

> **応答が返らなかった回は直前の絵で埋める。抜けを詰めない。** 詰めると「面が黙った」ことが動きから
> 消えてしまい、それ自体が見せたい事象であることがある
> ([#310](https://github.com/mokume-metal/mokume/pull/310#issuecomment-5452377415) が実例 — 窓を畳んだ後に
> 絵が凍るか回り続けるかの差が、70 枚のうち異なる絵の枚数として出た)。

> **採れる間隔は一定ではない。等間隔で束ねると、無かった動きを作ってしまう。** 1 枚ごとに応答を待つので、
> 1 枚あたりの間隔は絵の重さや機械の都合で揺れる。角度や位置が時刻の関数である以上、**揺れた間隔で
> 等間隔に束ねると、スケッチが速さを変えていないのに速さが変わって見える** — かつて観測を続けると
> フレームレート自体が落ちていた頃には、間隔が `0.248 秒 → 0.83 秒` と 3.3 倍に開き、
> **扇が 3.3 倍速で回り出す動画**になった ([#370](https://github.com/mokume-metal/mokume/issues/370) で解消)。
>
> だから **`timing.json` を採り、各フレームの表示時間を実際の間隔から決める** (下記)。そうすれば採取が
> 揺れても動画は実時間どおりになり、絵が実際に止まったときは「止まって見える」という**本当のこと**が映る。

### 撮り終えたら止める

**走らせたままにすると、次の撮影を前の版が答える。** 区画はディレクトリで決まるので、「shader を
before に戻して撮る → after に戻して撮る」を同じ場所でやると、1 回目のスケッチが生きている限り
**2 回目以降の要求もそれが答える**。応答は正常に返り、絵もちゃんと描けていて、**間違っているのは
「どの版が描いたか」だけ**である ([#1091](https://github.com/mokume-metal/mokume/issues/1091) の実測では
4 枚撮って 4 枚とも同じ版だった)。

**止め方は、起こした道具の PID へ素の `kill` を打つ。**

```bash
swift run mokume-cli watch <スケッチの場所> & tool=$!   # PID を控えてから撮る
# … 撮る …
kill "$tool"                                            # 配下のスケッチごと畳まれる
```

`run` も `watch` も、`SIGTERM` / `SIGHUP` を受けたらスケッチへ渡してから終わる
([#1193](https://github.com/mokume-metal/mokume/issues/1193))。**`$!` は道具の PID でよい** — `swift run`
は組んだ実行ファイルへ exec するので、番号は変わらない。**効かない撃ち方が 2 つある**:

| 撃ち方 | なぜ効かないか |
| --- | --- |
| `kill -9` (SIGKILL) | 渡す受け口が走らない。スケッチは `ppid=1` の孤児として**残り、観測に答え続ける** |
| 道具のプロセスグループごと (`kill -TERM -<pgid>`) | **スケッチは自分のプロセスグループに居る** (`Process` が新しいグループで起こす)。道具の側へ撃っても当たらない |

控え損ねたときは `bash scripts/orphan-processes.sh` が PID を出所つきで出す (AGENTS.md「手元に残ったプロセス」)。

> **`pkill -f` で掃くなら、綴りに気を付ける。** `ps` が見せるのは**起動時のパス**なので、`/tmp/…` で
> 起こしたスケッチは `/private/tmp/…` (`resolve()` した綴り) で照合すると **1 つも当たらない** — 掃いた
> つもりで全部残る。**照合はパスの末尾側で行う** (`pkill -f '<スケッチ名>/.build'` のように、
> 綴りが割れない所から下だけを書く)。

## B. 窓を撮る

窓の一覧を `gyazo_list_capturable_windows` で取る。**得た id はそのまま `screencapture` に渡せる。**

```bash
screencapture -l <windowId> -o shot.png       # 静止画 (窓の影を含めない)
screencapture -l <windowId> -V 5 motion.mov   # 5 秒の録画
```

**全画面 (`-l` を省く形) は撮らない** — 他アプリ・通知・手元のパスが写る。

### シート・パネルも `-l` が一緒に撮る

`-l` が撮るのは**窓とその子ウィンドウ**である。確認シートも、親の外へはみ出したパネルも同じ絵に入り、
親の id で撮っても子の id で撮っても**同じ絵**が返る (絵の大きさは親と子の合併矩形まで広がる)。
**子ウィンドウのために撮り方を変えなくてよい** ([#1127](https://github.com/mokume-metal/mokume/issues/1127) で実測)。

**背面のままで撮れる。** 他の窓の下にあっても、アプリが非活性でも、撮れた絵は同じである (実測)。
前へ出す操作は要らない — **出すと他の窓を隠してしまうので、撮れているなら出さない。**

**窓の外は透明で、背後のものは 1 画素も入らない** (実測。窓とパネルの隙間の画素が `RGBA 0,0,0,0`)。
`-l` を既定に据えているのはこれが理由で、**写り込みが起きないのは規律ではなく構造**である。

**撮れないときは、黙って親だけの絵にはならない。**

```
could not create image from window
```

と名乗り、ファイルを作らずに終わる。**窓が「いま画面に出ている窓」から消えているとき**にこうなる
(別の Space に居る・畳まれている)。下の一覧の `optionOnScreenOnly` 版から消えているかで見分けられ、
`gyazo_list_capturable_windows` に出ないのも同じ原因である。**対処は窓をいまの画面へ出して打ち直す**こと:

```bash
osascript -e 'tell application "System Events" to set frontmost of first process whose unix id is <pid> to true'
```

**ここで領域を撮る形 (`-R`) へ逃げない。** 逃げた先が下記のとおり写り込む側だからである。

> **シートが写っていないなら、まだ下りていない。** 窓へ確認シートを要求しても、下りるまでには間があり、
> 要求が通らないこともある (実測で、同じコードが下りる回と下りない回があった)。撮る前に下の一覧で
> **子ウィンドウが居ること**を確かめ、撮った後も絵を見る — `-l` は在るものを落とさないので、
> 写っていなければ**画面にも無かった**ということである。

### 領域を撮る (`-R`) のは最後の手段

`-R <x,y,w,h>` は「その領域に**いま見えているもの**」を撮る。対象が前面でなければ手前のアプリの中身が入り、
**別の Space に居れば対象は 1 画素も写らない** — 前面へ出した後でも起こる。
[#1127](https://github.com/mokume-metal/mokume/issues/1127) の実測では、無関係のアプリの画面を撮った
ファイルが 2 度できて破棄した。使うなら前面へ出してから撮り、**上げる前に撮った絵を目で確かめる**
(「守ること」の 1 つ目)。

矩形は撮る側からは見えないので、窓の一覧から引く。`gyazo_list_capturable_windows` が返すのは id と名前
だけなので、矩形と子ウィンドウはこちらで見る。**返る座標は左上原点で、`-R` がそのまま要求する形である。**
シートも 1 つの窓として出る (表題は空) ので、**親の外へ出る子ウィンドウがあるか**もここで分かる:

```bash
swift - <<'WINDOWS' | grep <アプリ名>
import CoreGraphics

// 画面に出ている窓も、出ていない窓も返る。表題が空の行は子ウィンドウ (シート・パネル)。
// [] を [.optionOnScreenOnly] にすると、いま画面に出ている窓だけになる — `-l` が撮れるのはこちら。
let all = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] ?? []
for window in all where (window[kCGWindowLayer as String] as? Int) == 0 {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let name = window[kCGWindowName as String] as? String ?? ""
    print(window[kCGWindowNumber as String] ?? "", window[kCGWindowOwnerPID as String] ?? "",
          window[kCGWindowOwnerName as String] ?? "", "'\(name)'",
          bounds["X"] ?? "", bounds["Y"] ?? "", bounds["Width"] ?? "", bounds["Height"] ?? "")
}
WINDOWS
```

**MCP の一覧に出ない窓もここには出る** — あちらが返すのはいま画面に出ている窓だけなので、
**目的の窓がこちらにしか無ければ、それは別の Space に居るということ**である (`-R` を打っても写らない側)。

## 動きを束ねる — 形式は宛先で決まる

| 宛先 | 静止画 | 動き | 使えないもの |
| --- | --- | --- | --- |
| PR / Issue (本線 = Gyazo) | PNG | **WebP** | mp4 |
| PR / Issue (退避路 = GitHub) | PNG | **WebP** | — (mp4 も通る) |
| 参照の面 | PNG | **GIF** | WebP / mp4 |

PR / Issue へ WebP を使うのは、同じ絵で GIF より小さく、色数が多くても劣化しないため。
**参照の面は WebP を警告も出さずに落とす**ので、そちらへ出すものだけ GIF にする。

**上げ先が本線でも退避路でも、動きの形式は同じ WebP でよい** (2026-09-22 実測・
[#1332](https://github.com/mokume-metal/mokume/issues/1332))。退避路の入力欄が名乗る `accept` には
`.webp` も `.mp4` も並んでおり、上げてみると**原本と SHA-256 まで一致し、コメントの中でも動いて描かれた**。

> **当初は退避路だけ GIF と決めていた。** 根拠は「GitHub は WebP を添付形式に持たない」「paste が
> 受け取るのは画像だけで動画は落ちる」「mp4 は drop でしか通らず小さいものに限る」の 3 つだった
> ([#1306](https://github.com/mokume-metal/mokume/issues/1306))。**3 つとも、いまの経路には当てはまらない** —
> 最初の 1 つは測り直すと成り立たず、残る 2 つは**クリップボード経由で運んでいた頃の制約**である
> (下の「退避路」節。いまはバイト列をブラウザの道具が運ぶので、道具の引数には載らない)。
> **mp4 も通る**が、動きの既定は WebP のままでよい — 本線と同じものをそのまま出せれば、上げ先が
> 切り替わっても束ね直しが要らない。

> **落ち方が「無言」である**ことを実測で確かめてある ([ADR-0027](../../../docs/decisions/0027-readable-surfaces.md)
> の「測ったこと」)。WebP を指した参照は本文から丸ごと消え、周りの文だけが残る — ビルドは緑・警告も
> 無しなので、**公開された面を見るまで気付けない**。
>
> 面を作る道具そのものは `@Video` で mp4 を扱えるが、**上げる経路が無い** (下記「うまくいかないとき」)。
> 動きを参照の面へ出す手段は、いまのところ GIF だけである。

**A は連番がそのまま手に入る**ので、束ねる所から始める。B は録画なので、まず連番へ起こす。

```bash
# 録画から連番へ (B のみ・幅 720 / 15fps が目安)
ffmpeg -y -i motion.mov -vf "fps=15,scale=720:-1:flags=lanczos" frames/f.%04d.png

# PR / Issue へ出す — WebP (本線・退避路とも同じ。B は録画なので等間隔でよい。既定が可逆で 1 ビットも劣化しない)
img2webp -loop 0 -d 67 frames/f.*.png -o motion.webp

# 参照の面へ出す — GIF (パレットを作ってから通す。**PR / Issue には要らない**)
ffmpeg -y -i motion.mov -vf "fps=15,scale=720:-1:flags=lanczos,palettegen" palette.png
ffmpeg -y -i motion.mov -i palette.png \
  -lavfi "fps=15,scale=720:-1:flags=lanczos,paletteuse" -loop 0 motion.gif
```

`-d` はフレーム間隔 (ミリ秒。15fps なら 67)。

**非可逆にはしない。** `-mixed` (フレームごとに可逆 / 非可逆を選ばせる指定) を付けると、この絵では
90 フレーム全部が非可逆側へ倒れ、**淡い階調が丸ごと潰れて 16px の段差に置き換わる** — 絵は正しく
描けているのに、貼られたものを見ると壊れているように見える
([#369](https://github.com/mokume-metal/mokume/issues/369) で実測。誤差は最大 84 階調、画素の 18% が
4 階調以上ずれ、フレームを追うごとに悪化した)。証跡は「元の絵に無いものが足されていないこと」に
価値がある。

**本線 (Gyazo) は 4MB を目安に収める。** GitHub は**外から来た画像を** camo 経由で出すので、詰まるのは
Gyazo (40MB) ではなく必ずこちらである。5,242,880 バイトを超えると `Content length exceeded` で 404 になり、**その手前でも
大きいと途中で切られる** — 4.6MB のものが 3.4MB で打ち切られ、それが `x-cache: HIT` のまま
`max-age=31536000` (1 年) で焼き付いた ([#369](https://github.com/mokume-metal/mokume/issues/369) で実測)。
壊れた側を引くかはエッジ次第なので、**貼った本人には正しく見えることがある**。実測では 3.7MB は 8 回とも
無事で、4.6MB が壊れた。

超えたときは**可逆の枠内で落とす** — `-near_lossless` は可逆圧縮の中で値を丸めるだけなので、段差が出ない:

```bash
img2webp -loop 0 -near_lossless 60 -d 67 frames/f.*.png -o motion.webp   # 最大誤差 2 階調
img2webp -loop 0 -near_lossless 40 -d 67 frames/f.*.png -o motion.webp   # 最大誤差 4 階調
```

それでも収まらないなら**短くする / 小さくする**。`-mixed` へ戻る段は作らない — 情報が減るのと、
元に無いものが足されるのは別である。

**退避路 (GitHub) は camo を通らない。** `github.com/user-attachments/…` は GitHub 自身の面なので、
markdown は素の `<img src>` のまま出す ([#1306](https://github.com/mokume-metal/mokume/issues/1306) で実測)。
したがって上の 4MB の目安も、途中で切られる壊れ方も**こちらには無い**。代わりに効くのは GitHub の
受け入れ上限で、**画像と GIF が 10MB・動画が 10MB (有料プランのリポジトリは 100MB)・その他が 25MB** である。

**A は `-d` を採った間隔から 1 枚ずつ決める** (`-d` はファイルごとに効く)。等間隔で束ねてはいけない理由は
経路 A の注意書きのとおり。

```bash
python3 - frames motion.webp <<'BUNDLE'
import json, pathlib, subprocess, sys

out = pathlib.Path(sys.argv[1])
rows = json.loads((out / "timing.json").read_text())
arguments = ["img2webp", "-loop", "0"]   # 既定が可逆。-mixed は付けない (下記)
for current, following in zip(rows, rows[1:]):
    gap = max(1, round((following["at"] - current["at"]) * 1000))
    arguments += ["-d", str(gap), str(out / current["file"])]
subprocess.run(arguments + ["-d", "100", str(out / rows[-1]["file"]), "-o", sys.argv[2]], check=True)
BUNDLE
```

## 上げる

**本線は Gyazo、落ちていれば GitHub へ退避する。** 判定は下の「落ちているかを見分ける」が持つ。

### 隔離 worktree のサブエージェントは、上げる手前で親へ渡す

`isolation: "worktree"` で起こされたサブエージェントは、**撮る・束ねる・`desc` を組むところまでで止まる。**
ここから下 (本線・退避路への上げ、落ちているかの見分け、退避路と camo の検算、公開のための投稿、消す操作) は、
起こした親が打つ。親が無人でも分担は変わらない — 無人の親が退避路を通せないときは、退避路の節にある
「Draft に落として返す」に落ちる。

親へ返すのは次の 5 つである:

- 上げるファイルの絶対パス
- `title`
- `desc` (本文か、`desc.txt` の絶対パス)
- 宛先 (PR / Issue の番号)
- 撮影範囲と意図 (「貼る」節の、動きに添えるテキスト)

置き場は **worktree の外で親から読める所** (作業用の一時領域など) にし、**Issue 番号で分ける**。
隔離 worktree は変更が無ければ worktree ごと消えるので、中に置いた材料も一緒に消える。一時領域は並行する
兄弟のサブエージェントと共有されうるので、番号で分けないと取り違える。

**止められたら、止められた 1 行を書き換えて通そうとしない。** そこで手を止め、上の材料を親へ返す。
この節の手順を打つと、隔離 worktree では Claude Code のガードに止められる — 中身を検証できない
コマンドを通さない、という守りである。止められた中身をスクリプトへ移す・綴りを割るなどして検査から
見えない形で通すと、守りを外すことになる。親はこの検査を受けないので、同じ行を変えずにそのまま打てる
([#1494](https://github.com/mokume-metal/mokume/issues/1494))。

### 本線 — Gyazo へ上げる

トークンは **`MOKUME_GYAZO_TOKEN_CMD`** に「トークンを標準出力に出すコマンド」を渡して読む。
App の秘密鍵 (AGENTS.md 「エージェントの identity」) と同じ流儀で、**値も在処もリポジトリに書かない**。

```bash
GYAZO_TOKEN="$(eval "$MOKUME_GYAZO_TOKEN_CMD")" && curl -s \
  -F "access_token=${GYAZO_TOKEN}" \
  -F "imagedata=@motion.webp" \
  -F "title=<人が読む一言>" \
  -F "desc=<desc.txt" \
  -F "app=mokume" \
  -F "referer_url=https://github.com/mokume-metal/mokume/pull/<N>" \
  -F "metadata_is_public=true" \
  https://upload.gyazo.com/api/upload
```

**代入から始めて `&&` で繋ぐ。** `export GYAZO_TOKEN="$(...)"` と書くと終了コードが `export` のもの (0) に
化け、読み出しに失敗しても後続が走る。

返る `url` (`https://i.gyazo.com/<id>.webp`) をそのまま貼る。

`desc` に書くのは **画像だけ見て疑問に思うこと**に絞る。観測の応答と git から組み立て、手で書かない。

```
mokume <版> / stamp <刻印>
sketch: <リポジトリ相対パス> @ <SHA>
frame 128 (2.13s) / 800x600 / 59.9fps
```

`metadata_is_public=true` で**公開される**ので、載せるのはリポジトリ相対パス・SHA・版に限る。
手元の絶対パスやマシン名は入れない。

### 落ちているかを見分ける

**upload が通っても、URL が読めるとは限らない。** 返った URL を必ず引いて確かめる:

```bash
curl -sI "$GYAZO_URL" -o /dev/null -w '%{http_code}\n'   # 200 でなければ退避路へ
```

**200 でなければ、指示を待たずに退避路へ落ちる。** upload 自体が失敗したときも同じ。

**HEAD (`-sI`) でよいのは、`i.gyazo.com` が転送を挟まず画像を直接返すからである。** 退避路の URL には
この打ち方が通らないので、あちらは別の 1 手を持つ (「退避路の検算」)。

この 1 手を置くのは、[#1294](https://github.com/mokume-metal/mokume/issues/1294) が
**「貼ったつもりで死んでいる」**形で現れたからである — 上げた側は成功しており、気付けるのは
引いてみたときだけだった。

### 退避路 — GitHub へ直接上げる

GitHub には添付の API が無い。REST にも GraphQL にも口が無いので、この経路は**ブラウザを操作できる
セッションでしか通らない** (「前提」節)。通る形は 1 つだけである — **ページの `input[type=file]` へ
ファイルを渡す。** クリップボードは経由しない (下の「通らない道」)。

**その入力欄が在るかは面で違う** (2026-09-22 実測・[#1332](https://github.com/mokume-metal/mokume/issues/1332)):

| 面 | `input[type=file]` |
| --- | --- |
| **PR** のコメント欄 | **在る** — `id="fc-new_comment_field"`。`accept` は `.gif,.jpeg,.jpg,.mov,.mp4,.png,.svg,.webm,.webp,…` |
| **Issue** のコメント欄 (React の新 UI) | **無い** — 「Paste, drop, or click to add files」は `<button>` で、欄は押すまで DOM に現れない |

**だから手順は「無ければ自分で置く」形にする。** そうすれば面を問わず 1 つの手順で通り、
GitHub がどちらの UI を出していても分岐が要らない。

手順は 5 手:

**1. 入力欄を用意する。** PR なら `fc-new_comment_field` をそのまま使う。無い面では注入する:

```javascript
const staging = document.createElement('input');
staging.type = 'file';
staging.id = 'mokume-evidence-input';
staging.setAttribute('aria-label', 'mokume evidence staging file input');  // find が拾えるように
staging.style.cssText = 'position:fixed;top:0;left:0;z-index:99999;background:#fff';
document.body.appendChild(staging);
```

**2. その欄へファイルを渡す** (ブラウザ道具の file upload。要素の参照は `find` で取る)。
**手元のバイト列をページへ運べるのはこの 1 手だけ**で、他の運び方は下の表のとおり通らない。

**3. 注入した欄を使ったときは、コメント欄へ `paste` を合成して渡し直す** (`fc-new_comment_field` へ
直接渡したときは、GitHub 自身の受け口なので要らない):

```javascript
const file = document.getElementById('mokume-evidence-input').files[0];
const area = document.querySelector('textarea');          // コメント欄
area.focus();
const carrier = new DataTransfer();
carrier.items.add(file);
area.dispatchEvent(new ClipboardEvent('paste', {clipboardData: carrier, bubbles: true, cancelable: true}));
```

**4. 数秒おいて、挿入された 1 行をコメント欄の値から取り出す。** 画像は
`<img width="…" height="…" alt="…" src="https://github.com/user-attachments/assets/<uuid>" />`、
動画は**裸の URL 1 行**である (`![]()` では囲まない)。

**5. 注入した欄を外し、下書きを空にしてタブを閉じる** (投稿はラッパー経由で行うので、欄に残った本文は捨てる)。

> **上がったものは原本とバイト単位で一致する。** PNG 2 本・WebP・mp4 の計 4 本で **SHA-256 まで一致**した
> ([#1332](https://github.com/mokume-metal/mokume/issues/1332))。**動きを束ね直す必要は無い** —
> 本線と同じ WebP をそのまま出せる。

**URL は投稿して初めて生きる。** 貼った時点では公開されず、無認証で引くと **404** が返る
(上げた本人のセッションからだけ読める)。**公開になるのは、その URL が新しく投稿されたコメントに
現れたとき**である。

```bash
bash scripts/comment.sh {issue,pr} <番号> --body-file <ファイル>
```

> **公開は少し遅れて効く。投稿直後の 404 は「失敗」ではなく「まだ」である** — 数十秒おいて引き直す
> ([#1332](https://github.com/mokume-metal/mokume/issues/1332) で実測)。
>
> **上げた欄と、公開のために投稿する先は別でよい。** PR のコメント欄で上げた添付を Issue へ投稿しても
> 公開された — 添付はスレッドに縛られていない。**Issue へ絵を貼るために、Issue 側で上げ直さなくてよい。**

> **PR 本文へ載せたいときも、先にコメントで投稿する。** `gh pr edit --body` で本文へ URL を書いても
> **公開されない** — 本文の編集は「新しい投稿」に数えられず、404 のままである
> ([#1306](https://github.com/mokume-metal/mokume/issues/1306) で実測。同じ URL をコメントとして投稿した
> 途端に 200 になった)。**`drawing-evidence` が読むのは PR 本文**なので、描画 PR ではこの順を守る:
>
> 1. コメント欄へ貼って URL を得る
> 2. **その URL を含むコメントを投稿する** (`scripts/comment.sh`) — ここで公開される
> 3. 同じ URL を PR 本文へ書く (`gh pr create --body-file` / `gh pr edit --body-file`。発言ではないのでラッパーは通さない)

**無人セッション (`MOKUME_UNATTENDED=1`) ではこの経路は使えない。** ブラウザを操作できないためである。
Gyazo も落ちていて証跡を残せないときは、**そのことを PR 本文に書いて Draft に落とし、有人のセッションへ返す** —
絵の無い描画 PR は `drawing-evidence` が赤で差し戻すので、黙って進めても merge できない。

**退避路が効くのは PR / Issue の一回限りの証跡までで、参照の面 (`make example-shots`) には使わない。**
あちらは「同じ中身の絵には同じ URL が返る」という Gyazo の冪等性を借りており、**撮り直して URL が
変わったかがそのまま絵が変わったかの判定**になっている ([ADR-0027](../../../docs/decisions/0027-readable-surfaces.md)
決定 2)。GitHub の添付は同じ絵でも毎回別の URL を返すので、この判定が成り立たない。

#### 通らない道 — 試して時間を落とさないために

**どれも「バイト列をページへ運ぶ」ところで止まる。** 上の手順 2 が 1 手だけなのはこのためである。

| 試したこと | なぜ通らないか |
| --- | --- |
| `osascript` でクリップボードへ載せて `cmd+v` を合成する | 合成したキー入力はページへ届くだけで、**ブラウザの貼り付けコマンドを起こさない**。OS のクリップボードは読まれず、欄は空のまま |
| ページ内で `navigator.clipboard.read()` を呼ぶ | 読み取り権限が要り、自動操作には降りない (`NotAllowedError: Read permission denied`) |
| base64 を JavaScript のソースへ書き写して `File` を組む | 大きな文字列が道具の引数の途中で欠ける (14010 B のはずが 11571 B で上がった) |
| ページ内から `fetch` で手元のバイト列を取る | GitHub の CSP (`connect-src`) が外す |

**4 つとも 2026-09-22 実測** ([#1320](https://github.com/mokume-metal/mokume/issues/1320) /
[#1332](https://github.com/mokume-metal/mokume/issues/1332))。**クリップボードを使う形は、上の 1 行目の
理由で構造的に通らない** — 手順から外したのは作法の好みではない。

### 退避路の検算

**GET でリダイレクトを追い、原本とバイト数を突き合わせる。**

```bash
curl -sL "$ATTACHMENT_URL" -o /tmp/pulled -w '%{http_code} %{size_download}\n'
wc -c "<上げた原本>"                                                     # 一致すること
shasum -a 256 /tmp/pulled "<上げた原本>"                                 # 突き合わせを強めるなら
```

**見るのは 200 ではなくバイト数の一致である。** 200 だけでは「途中で切られていない」ことが見えず
([#369](https://github.com/mokume-metal/mokume/issues/369) が camo で踏んだ形)、一致は**貼ったものが
原本である**ことまで言う。退避路は camo を通らないので切られる余地は無いが、同じ 1 手で両方を確かめられる。

**本線 (`i.gyazo.com`) と打ち方が違うのは、こちらが画像を直接返さないからである** — `github.com/user-attachments/…`
は署名付き S3 への 302 で、**presigned URL は GET 用に署名されているので HEAD は 403 で弾かれる**。
`-sI` で打つと、正しく公開されている添付が「失敗」に見える ([#1310](https://github.com/mokume-metal/mokume/issues/1310))。

| 打ち方 | 返るもの (2026-09-22 実測・[#1293](https://github.com/mokume-metal/mokume/pull/1293) に貼った添付) |
| --- | --- |
| `curl -sI` (HEAD・追わず) | **302** — `github-production-user-asset-….s3.amazonaws.com` への署名付き転送 |
| `curl -sIL` (HEAD・追う) | **403** — presigned URL が GET 用に署名されているため HEAD が弾かれる |
| `curl -s` (GET・追わず) | 302 |
| `curl -sL` (GET・追う) | **200** / 7182 bytes / `image/png` — 手元の原本とバイト数一致 |

## 貼る

**コードは Gyazo ではなく GitHub 側に持つ。** `desc` は後から直せず、貼った画像からも読めないためである
(Gyazo 側に置くのは、画像から離れず・直す必要が生じない事実だけ)。

- リポジトリにあるコードは **行範囲つきの恒久リンクで指す** — 写さないので長さの問題が起きない
- 証跡のための使い捨てスケッチだけ `<details>` に全文を入れる。**1 ファイルに収める** — 収まらないなら、
  それは使い捨てではなくリポジトリに入れるべきものである

before / after は表で並べ、**幅を宣言する**。

```markdown
| before (main) | after (this PR) |
| --- | --- |
| <img src="https://i.gyazo.com/<id>.png" width="480"> | <img src="https://i.gyazo.com/<id>.png" width="480"> |
```

**素の `![]()` で並べると大きさが揃わない。** 表の列幅は中身の自然幅から比例配分されるので、原寸の差が
そのまま表示の大小になる — 静止画は観測が返した解像度をそのまま上げるのに対し、動きは `scale=720:-1` で
幅が固定されるため、静止画と動きを並べた表では**動きだけが小さく出る**
([#371](https://github.com/mokume-metal/mokume/issues/371)。[#364](https://github.com/mokume-metal/mokume/pull/364) が
960px と 720px で並んでいた)。同じ `width` を両方へ書けば揃い、GitHub は `width` を残したうえで
`max-width: 100%` を付けるので、画面が狭いときも同じ割合で縮む。

**揃えるのは幅の側で、書き出しの側ではない。** 静止画の解像度はスケッチごとに変わるので、`scale` を
それに合わせると撮るたびの作業になり、幅を上げるとファイルも太る。

静止画と動きを並べる表も同じ書き方でよい (アスペクト比が同じなら高さも揃う)。**単独で貼る絵は原寸の
ままでよい** — 幅を書くのは並べるときだけである。

**動きには撮影範囲と意図をテキストで添える。** フレームを人が後から検める代わりの記録なので、
何を撮ったか (A なら観測したスケッチと条件・B ならどの窓)・どの操作の何秒間か・どこを見てほしいかを書く。

**本線 (Gyazo) で貼ったら camo 側を検算する。** 上のとおり camo は大きいものを途中で切ることがあり、切れた側が
キャッシュに焼かれる。**Gyazo の URL を直接叩いても気付けない** (あちらは無事なので) ので、貼った本文から
camo URL を取り、何度か叩いて**原本と同じ長さが返るか**を見る:

```bash
gh api repos/mokume-metal/mokume/pulls/<N> -H 'Accept: application/vnd.github.html+json' --jq .body_html \
  | grep -oE 'https://camo\.githubusercontent\.com/[a-f0-9]+/[a-f0-9]+' | sort -u \
  | while read -r u; do
      for _ in 1 2 3; do curl -sS -o /dev/null -w "%{size_download} " "$u"; done; echo " $u"
    done
```

長さが原本と違ったら、**上げ直して URL を変える**しかない (camo のキャッシュは消せない)。同じ絵を
上げ直しても同一バイトなら Gyazo が同じ id を返すので、**先に小さくしてから上げる**。

**貼った直後は camo URL が取れない。** `body_html` は少しの間 camo 化前を返すので、すぐ叩くと
「camo URL が 1 つも無い」で素通りしてしまう ([#374](https://github.com/mokume-metal/mokume/issues/374)
で実測。20 秒ほどで書き換わった)。**取れた URL の数が貼った絵の数と合っているか**を先に見る。

**退避路 (GitHub) で貼ったものに、この検算は要らない。** `github.com/user-attachments/…` は camo を
通らないので切られる余地が無い ([#1306](https://github.com/mokume-metal/mokume/issues/1306) で実測)。
代わりに見るのは 1 つだけ — **「退避路の検算」を投稿した後に打って、原本と同じバイト数が返るか**である
(投稿前は 404 のままなので、確かめるのは必ず投稿の後。`-sI` では 302 が返るので、200 を待っても来ない)。

## 守ること

- **before / after を撮ったら、2 枚が同じでないことを確かめる** (`cmp -s before.png after.png`)。同じなら、
  それは「絵が変わらなかった」ではなく**前の版が答えた疑い**である — 走らせたままのスケッチが次の要求にも
  答えるためで、応答にも絵にも失敗が出ない ([#1091](https://github.com/mokume-metal/mokume/issues/1091))。
  切り分けは `bash scripts/orphan-processes.sh` — 落とし損ねたスケッチが居ないかを見る
- **上げることは外部サービスへの送信である。** 送る前に写り込み (他アプリ・通知・手元のパス・秘密) を
  確かめる。判断がつかなければ聞く
- **動きのフレームは読み込んで検めない** — 全フレームの画像読み込みは高くつき、写り込みの確率に
  見合わない。代わりに上の「撮影範囲と意図」を書く。後から見つかったときは消す (下記)
- 証跡はリポジトリにコミットしない (`scripts/check-no-binaries.sh` が弾く)

## うまくいかないとき

- **同じ絵を上げ直したのにメタデータが変わらない** — 同一バイトの画像には既存の id が返り、
  メタデータは更新されない。決定論で撮り直して絵が同じなら、新しい `desc` は無視される
- **`desc` が自分にしか見えない** — `metadata_is_public=true` が要る。付けないと第三者からは読めない
- **`desc` を間違えた** — 後からは直せない。消して上げ直すことになり、URL が変わって貼った先が壊れる。
  貼る前に読み返す
- **写り込みに後から気付いた / 消したい (本線)**

  ```bash
  GYAZO_TOKEN="$(eval "$MOKUME_GYAZO_TOKEN_CMD")" && curl -s -X DELETE \
    -H "Authorization: Bearer ${GYAZO_TOKEN}" https://api.gyazo.com/api/images/<image_id>
  ```

  permalink が 404 になる。**貼った先の画像も消えるので、貼り直しまで面倒を見る**
- **写り込みに後から気付いた (退避路)** — **こちらには消す口が無い。** 本文から URL を外しても
  添付そのものは残り、URL を知っていれば引ける。**だから退避路では「送る前に確かめる」が唯一の防壁**である
  (「守ること」節)。それでも出してしまったら、リポジトリの外に出た秘密として人に報告する
- **mp4 を貼りたい** — **本線 (Gyazo) には経路が無い** (アップロード API が受け付けず、埋め込んでも
  展開されない)。**退避路では通る** — `accept` に載っており、83202 B のものが SHA-256 一致で上がった
  ([#1332](https://github.com/mokume-metal/mokume/issues/1332))。ただし**動きの既定は WebP のまま**でよい
  (本線と同じものをそのまま出せる)。参照の面を作る道具の側は `@Video` で mp4 を扱える (実測) が、
  **置き場が無いので使えない**
- **退避路で上げた絵が、投稿したのに 404** — **公開は少し遅れて効く。** まず数十秒おいて引き直す
  ([#1332](https://github.com/mokume-metal/mokume/issues/1332) で実測)。それでも 404 なら
  **その URL を含むコメントをまだ投稿していない** — 貼った時点では公開されず、上げた本人のセッションから
  しか読めない。**PR 本文へ書いただけでも公開されない**ので、コメントとして投稿してから引き直す。
  **未投稿を名乗るのは 404 だけ**である (下の行)
- **退避路の検算が 302 / 403 を返す** — **添付は公開されていて、打ち方が合っていないだけである。**
  `-sI` / `-s` は署名付き S3 への転送 (302) が返ったところで止まっており、`-sIL` は presigned URL が
  GET 用に署名されているため HEAD が弾かれている (403)。`-sL` で GET で追い直す (「退避路の検算」)。
  **これを「まだ公開されていない」と読んで Draft に落とさない** — 上げ先が 2 本とも塞がったように
  見えて、描画 PR が 1 本も出せなくなる ([#1310](https://github.com/mokume-metal/mokume/issues/1310))
- **退避路で貼っても入力欄が空のまま (エラーも出ない)** — クリップボード経由で運ぼうとしている。
  合成したキー入力はブラウザの貼り付けコマンドを起こさない (「通らない道」)。**`input[type=file]` へ
  渡す形**に置き換える
- **注入した入力欄が `find` で見つからない** — `aria-label` を付けていない。画面外や
  `display:none` にも置かない (拾えなくなる)
- **退避路で貼った動きが 1 枚の静止画になっている / 形式が受け付けられない** — 上がったものは
  **原本とバイト単位で一致する**ので、この経路では起こらない。起きたなら渡したファイルのほうを疑う
  (`shasum -a 256` で原本と突き合わせる)
- **ブラウザが繋がらない** — 退避路はブラウザを操作できるセッションでしか通らない。Gyazo も
  落ちているなら証跡は残せないので、**PR にそう書いて Draft に落とし、有人のセッションへ返す**
- **貼った絵が表示されない / 途中までしか動かない** — camo で詰まっている。5MB 超なら 404
  (`Content length exceeded`)、その手前なら途中切断が焼き付いている。**Gyazo 側は生きているので、URL を
  直接叩くと取れてしまい気付きにくい** — 「貼る」節の検算で camo 側の長さを見る。直すには小さくして
  上げ直す (URL が変わるので貼り直しまで面倒を見る)
- **貼った動きに 16px の四角い段差が見える / 淡い階調が消えている** — `-mixed` か `-lossy` で束ねている。
  可逆で束ね直す ([#369](https://github.com/mokume-metal/mokume/issues/369))
- **before / after が同じ絵になる / 撮り直しても絵が変わらない** — 前の版のスケッチが生き残って答えて
  いる。`bash scripts/orphan-processes.sh` で PID を見て落としてから撮り直す (A の「撮り終えたら止める」)
- **観測が「走っているスケッチが応えませんでした」と返る** — 案内が**区画をこの呼び出しで作った**と言って
  いれば、区画を起動より後に作っている (A の順序を見る)。区画はもう在るので、**起動し直すだけ**でよい。
  案内が**区画は要求を置く前から在った**と言っていれば順序の問題ではなく、そもそも走っていない
- **窓の一覧に目的の窓が出ない** — 一覧が返すのは**いま画面に出ている窓**である。背面で起動した
  (`nohup` 等) スケッチや、最小化・別の Space にある窓は出てこない。前に出してから取り直す
- **`could not create image from window` で撮れない** — `-l` は窓が**いま画面に出ている窓から消えている**と
  こう名乗って終わる (上の「一覧に出ない」と同じ原因。背面にあるだけなら撮れる)。**いまの画面へ出して
  打ち直す** — `-R` へ逃げると写り込む
- **窓の一覧が空 / 撮れない** — 画面収録の許可が要る。**付与は GUI 操作なので代行せず頼む**
- **`unauthorized`** — トークンを作り直す (https://gyazo.com/oauth/applications)。OAuth フローは要らず、
  developer ページで出せる 1 本でよい

## 前提

本線と退避路で要るものが違う。**退避路は秘密を 1 つも要らない代わりに、有人のセッションを要求する。**

| | 本線 (Gyazo) | 退避路 (GitHub) |
| --- | --- | --- |
| 束ねる道具 | `img2webp` (`brew install webp`) と `ffmpeg` | 同じ (動きの形式は本線と揃う) |
| 秘密 | `MOKUME_GYAZO_TOKEN_CMD` | 要らない |
| セッション | 無人でも通る。**隔離 worktree のサブエージェントでは打たず、親が打つ** (「上げる」節の頭) | **ブラウザを操作できる有人のセッション**・GitHub にサインイン済み |
| その他 | — | **ページの `input[type=file]` へファイルを渡せるブラウザ道具** (file upload)。クリップボードは使わない |

- `img2webp` (`brew install webp`) と `ffmpeg`
- **Gyazo のアクセストークン。** https://gyazo.com/oauth/applications でアプリを登録すると出せる
  (OAuth フローは要らず、developer ページで出せる 1 本でよい)。環境変数 **`MOKUME_GYAZO_TOKEN_CMD`** へ
  「トークンを標準出力に出すコマンド」を渡し、手元の秘密管理から読ませる — 値そのものを環境変数に置かない
- 窓の一覧には Gyazo の MCP サーバーが要る (開発者向けプレビュー版・公式サポート対象外で、
  仕様が変わることがある)
