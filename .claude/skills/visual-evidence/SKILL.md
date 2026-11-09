---
name: visual-evidence
description: 描画結果・動きが変わる変更を PR / Issue に記録するとき、スケッチの絵やウィンドウの様子をアップロードして URL を得る。通常の経路は Gyazo で、落ちていれば GitHub の添付へフォールバックする。撮影の経路・宛先ごとの形式・出所の残し方を扱う。Use when attaching visual evidence to a pull request or issue, when a drawing or motion change needs before/after images, when capturing an animated WebP or GIF, when Gyazo is unavailable or its URLs return 404, or when embedding images in docs.
allowed-tools: "mcp__gyazo-mac__gyazo_list_capturable_windows"
---

<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 視覚証跡を残す

何を載せるかの規律は AGENTS.md「絵」が正本で (描画が変わらなくても、見て分かるものは気軽に
載せる — [#2195](https://github.com/mokume-metal/mokume/issues/2195))、ここは手順だけを持つ。CI は描画を実行できない
([#180](https://github.com/mokume-metal/mokume/issues/180)) ので、**PR に貼った絵が描画の唯一の検証記録になり、
squash merge の後には足せない。** 人なら入力欄へ画像をドロップするだけでよく、この文書はエージェントの手順を扱う。

| 場面 | 読む先 |
| --- | --- |
| draw() の短いコードから撮る (Issue の再現など) | 下の「最短」 |
| スケッチの絵を撮る (既定) | この文書 |
| ウィンドウ・GUI・操作そのものを撮る | [window.md](window.md) |
| Gyazo が落ちている (「落ちているかを見分ける」で 200 が返らない) | [fallback.md](fallback.md) |
| 複数の変更を人が確認する報告へまとめる | [report.md](report.md) |

**撮影と送信は分ける。** 手元に保存してからアップロードし、外部へ送る前に写り込みを確認する。Gyazo の MCP の
「撮影して即座にアップロードする」ツールは使わず、ウィンドウの一覧だけを取得する (`allowed-tools` がそれだけなのはこのため)。

## 最短 — コードから撮る (`--snippet`)

draw() の本体に書けるもの (Issue の再現・API の振る舞い・before/after) は、スケッチを用意せず
1 コマンドで撮れる。ドキュメントコメントの例を撮る仕組みを流用しており、撮るのは mokume の絵だけなので写り込みは無い。

```bash
python3 scripts/example-shots.py --snippet repro.swift --size 160x120          # 撮る (場所を出す)
python3 scripts/example-shots.py --snippet repro.swift --size 160x120 --upload \
  --token-command "$MOKUME_GYAZO_TOKEN_CMD"                                     # アップロードして Markdown を出力する
```

- `--zoom K` — 最近傍補間で K 倍に拡大する。1 ピクセルの継ぎ目・透け・AA の欠けは原寸では見えない
- `--frames N` — アニメーションにする (可逆の WebP。`img2webp` が要る)
- before/after は main のワークツリーと作業中のワークツリーで同じファイルを撮り、下の「貼る」の表で並べる
- スケッチの外 (ウィンドウ・GUI・`watch` の振る舞い) は経路 A か [window.md](window.md) の経路 B で撮る

## 撮る — スケッチの絵 (経路 A)

`observe` で撮れば、同じ条件で撮り直せ、他アプリの映り込みもウィンドウの位置への依存も無い。**`.mokume/observe` ディレクトリを作ってから起動する** —
`observe` は起動の瞬間にディレクトリがあるときだけ有効になる (`FrameObserver.makeIfEnabled`)。

```bash
mkdir -p <スケッチの場所>/.mokume/observe    # 起動より先に作る
swift run mokume-cli watch <スケッチの場所>  # ウィンドウが出る
swift run mokume-cli mcp <スケッチの場所>    # エージェント用の MCP サーバーを起動する
```

順を逆にすると、MCP サーバーが「ディレクトリはこの呼び出しで作ったので、起動し直してください」と返す。ディレクトリは作り直さず、
スケッチだけ起動し直す ([#227](https://github.com/mokume-metal/mokume/issues/227))。

MCP サーバーの `observe` は絵の場所と内訳 (フレーム番号・時刻・サイズ・絵の要約・負荷・スケッチが渡した値・
ビルドのスタンプ) を返す。**内訳はそのまま出所の記録になるので取っておく。** スタンプ (`stamp`) は `watch` で起動したときだけ
入り (`Sources/MokumeCLI/WatchSession.swift`)、`run` では何も出力されずに省かれる。スタンプが要るなら `watch` で起動する — `run` の出所は、どのバージョンをビルドしたかという
撮った本人の記録でしか示せない ([#1091](https://github.com/mokume-metal/mokume/issues/1091))。
MCP サーバーを立てず、`.mokume/observe/request.json` へ `{"id": "<毎回変える>"}` をアトミックに置いて
`report.json` の `id` が一致するまで待ってもよい (置き方・待ち方・絵のコピーの方法は `scripts/observe_lib.py` の
`place`・`answered`・`copy_image` / `copy_images`)。**絵は `.mokume/observe` の中で読まず、`copy_image` / `copy_images` でコピーする** — ディレクトリの中の絵は
次のリクエストで上書きされる ([#2992](https://github.com/mokume-metal/mokume/issues/2992))。

### 動きを撮る

識別子を変えながらリクエストを置き、応答の `image` が指す絵を退避すれば連番になる。`scale` を添えると
書き出しの時点で縮小される。**リポジトリのルートから実行する** (`scripts/observe_lib.py` を読むため)。

```bash
python3 - <スケッチの場所>/.mokume/observe frames 70 0.5 <<'CAPTURE'
import json, pathlib, shutil, sys, time, uuid

sys.path.insert(0, "scripts")
from observe_lib import Contested, Unverified, answered, copy_image, place   # 置き方・待ち方・写し方の正典はこれ 1 つ

facet, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
rounds, scale = int(sys.argv[3]), float(sys.argv[4])
out.mkdir(parents=True, exist_ok=True)
previous, timing = None, []
# 識別子は走らせるたびに変える。`.mokume/observe` ディレクトリが残っている間は同じ識別子を処理し直さない (Schemas/ の observe-request)
run = uuid.uuid4().hex[:8]

for index in range(1, rounds + 1):
    identifier = f"{run}-{index:04d}"
    before = place(facet, {"id": identifier, "scale": scale})

    name, taken, filled = f"f.{index:04d}.png", None, False
    try:
        report = answered(facet, identifier, 1.5, before=before)  # 壁時計ではなく識別子の一致で完了を知る
        if report:                                # 写してから、応答が自分のままかを確かめる (#2992)
            taken = copy_image(facet, report, identifier, out / name)
    except Contested as contest:                  # 別のプロセスが同じディレクトリを使っている。撮り続けない
        sys.exit(f"{index} 枚目で止めた: {contest}")
    except Unverified as unverified:              # コピーできない・確かめられないバージョン。他人の絵を並べず、埋めたことを報告する
        print(f"{index} 枚目は確かめて写せなかった: {unverified}", file=sys.stderr)

    if taken is None and previous:                # 返らなかったら直前の絵を置く。置いたことを報告する
        shutil.copy(previous, out / name)
        filled = True
        print(f"{index} 枚目は応答が無く、直前の絵を置いた", file=sys.stderr)
    previous = taken or previous
    timing.append({"file": name, "at": time.time(), "filled": filled})  # 何時に採れたか = その絵が出ていた長さ

(out / "timing.json").write_text(json.dumps(timing))
CAPTURE
```

- **置き方と待ち方はここへコピーしない。** 実装は `scripts/observe_lib.py` の 1 つ、形式の正本は `Schemas/` の
  `observe-request` / `observe-report` ([#817](https://github.com/mokume-metal/mokume/issues/817))。
  絵のファイル名も応答の `image` に従い、決め打ちしない
- **応答が返らなかった回は直前の絵で埋め、詰めない。** 「スケッチが応答しなくなった」こと自体が見せたい事象のことがある
  ([#310](https://github.com/mokume-metal/mokume/pull/310#issuecomment-5452377415))。**埋めたことは出力し**
  (標準エラーと `timing.json` の `filled`)、何も言わずに直前の絵を本物として並べない
- **別の書き込む側が同じディレクトリを使っていたら、撮り続けない** (`Contested`)。ディレクトリにはリクエストも応答も 1 つしか置けず、書き込む側どうしを
  調停しない。自分の識別子の応答はもう来ず、スケッチが動いていないのではない — 実行し直すのではなく、他の書き込む側が
  いなくなってから撮り直す
- **絵は応答を受けたらすぐ自分の保存先へコピーし、コピーした後の検証まで `copy_image` / `copy_images` に任せる**
  ([#2992](https://github.com/mokume-metal/mokume/issues/2992))。ディレクトリの中の絵は固定名で、別の書き込む側が撮影を始めると
  読む前に上書きされる。応答の `image` を後からディレクトリの中で読まない。競合したら `Contested` (絵は返らず、コピーも残らない)。
  応答が自分のままでコピーできなかった・マニフェストの無いバージョン (#408 より前。応答を消さずに絵を先に上書きするので検証が成り立たない)
  は `Unverified` — 競合ではないが、ディレクトリの中の絵 (`sources`) は次のリクエストまでしか自分の絵でない

### 撮り終えたら止める

**実行したままにすると、次の撮影に前のバージョンが応答する。** `.mokume/observe` の場所はディレクトリで決まるので、同じ場所で
before → after と撮ると、1 回目のスケッチが 2 回目にも応答する。応答も絵も正常で、
間違っているのは「どのバージョンが描いたか」だけである ([#1091](https://github.com/mokume-metal/mokume/issues/1091))。

起動したツールの PID へ素の `kill` を送る。`run` も `watch` も `SIGTERM` / `SIGHUP` をスケッチへ渡してから
終了し ([#1193](https://github.com/mokume-metal/mokume/issues/1193))、`swift run` は exec するので `$!` のままでよい。

```bash
swift run mokume-cli watch <スケッチの場所> & tool=$!   # PID を控えてから撮る
# … 撮る …
kill "$tool"                                            # 配下のスケッチごと終了する
```

| 効かない終了のさせ方 | 理由 |
| --- | --- |
| `kill -9` (SIGKILL) | シグナルを渡すハンドラが動かない。スケッチは `ppid=1` の孤児として残り、`observe` に応答し続ける |
| プロセスグループごと (`kill -TERM -<pgid>`) | スケッチは `Process` が起動した自分のグループにいるので届かない |

控え損ねたら `bash scripts/orphan-processes.sh` が PID を出所つきで出す。`pkill -f` でまとめて止めるときは、`ps` が
表示する起動時のパス (`/tmp/…`) と `resolve()` したパス (`/private/tmp/…`) で表記が分かれるので、
`pkill -f '<スケッチ名>/.build'` のように表記の分かれない末尾側で照合する (外すと 1 つもヒットせず全部残る)。

## 動きをエンコードする — 形式は宛先で決まる

| 宛先 | 静止画 | アニメーション | 使えないもの |
| --- | --- | --- | --- |
| PR / Issue (通常の経路 = Gyazo) | PNG | **WebP** | mp4 |
| PR / Issue (フォールバック = GitHub) | PNG | **WebP** | — (mp4 も通る) |
| リファレンス | PNG | **GIF** | WebP / mp4 |

WebP は GIF より小さく、色数が多くても劣化しない。アップロード先が切り替わってもエンコードし直す必要は無い。
経路 A の連番は撮れる間隔が揺れるので、`-d` (表示時間、ミリ秒) を `timing.json` の間隔から 1 枚ずつ決める。
**等間隔でエンコードすると、スケッチが速さを変えていないのに速さが変わって見える** ([#370](https://github.com/mokume-metal/mokume/issues/370))。

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

**可逆のままエンコードする。** `-mixed` や `-lossy` を付けると淡い階調が 16px の段差に潰れ、正しく描けた絵が
壊れて見える ([#369](https://github.com/mokume-metal/mokume/issues/369))。証跡の価値は、元の絵に無いものが
足されていないことにある。

**通常の経路は 4MB を目安に収める。** 詰まるのは Gyazo (40MB) ではなく GitHub の camo である。5,242,880 バイトを
超えると `Content length exceeded` で 404 になり、その手前でも途中で切られたものが 1 年キャッシュされる
(実測では 3.7MB は無事、4.6MB が壊れた — [#369](https://github.com/mokume-metal/mokume/issues/369))。
超えたら可逆の範囲内で小さくする — `-near_lossless` は可逆圧縮の中で値を丸めるだけで、元に無いものを足さない。それでも
収まらなければ短く / 小さくする。`-mixed` へ戻るステップは作らない (フォールバックは camo を通らず、上限も別 — [fallback.md](fallback.md) の「大きさの上限」)。

```bash
img2webp -loop 0 -near_lossless 60 -d 67 frames/f.*.png -o motion.webp   # 最大誤差 2 階調
img2webp -loop 0 -near_lossless 40 -d 67 frames/f.*.png -o motion.webp   # 最大誤差 4 階調
```

経路 A では `-d 67` で等間隔にせず、上の BUNDLE の `arguments` に `-near_lossless 60` を足す。

### リファレンスへ出す GIF

リファレンス (ADR-0027 の DocC で生成する参照ページ) は WebP を警告も出さずに捨て、参照ごと本文から消える (ビルドは成功する)。mp4 は DocC が `@Video` で
扱えるが、アップロードする経路が無い。だからリファレンスへ出すアニメーションだけ GIF にする
(理由: [ADR-0027](../../../docs/decisions/0027-readable-surfaces.md) 決定 2)。パレットを作ってから変換する (例は録画 `motion.mov` から):

```bash
ffmpeg -y -i motion.mov -vf "fps=15,scale=720:-1:flags=lanczos,palettegen" palette.png
ffmpeg -y -i motion.mov -i palette.png \
  -lavfi "fps=15,scale=720:-1:flags=lanczos,paletteuse" -loop 0 motion.gif
```

## アップロードする

**隔離されたサブエージェント (`isolation: "worktree"` など、ツール名によらない) は、撮影・エンコード・`desc` の
組み立てまでで止まる。** ここから下 (アップロード・見分け・確認・公開の投稿・削除) は親が実行し、親が無人でも分担は
変わらない (通せなければ [fallback.md](fallback.md) の「前提」のとおり Draft にする)。親へは、アップロードするファイルの
絶対パス・`title`・`desc` (本文か `desc.txt` の絶対パス)・宛先の番号・撮影範囲と意図を、worktree の外で親から
読める所に Issue 番号で分けて置いて返す (隔離 worktree は変更が無ければ消え、一時領域は並行する他のサブエージェントと共有されうる)。
ここの手順はガードに止められるが、**止められた行をスクリプトへ移す・文字列を分割するなどして通さない** — 検証
できないコマンドを通さない防御を外すことになる。親は同じ行をそのまま実行できる ([#1494](https://github.com/mokume-metal/mokume/issues/1494))。

### 通常の経路 — Gyazo へアップロードする

トークンは `MOKUME_GYAZO_TOKEN_CMD` から読む (「前提」)。代入から始めて `&&` で繋ぐ —
`export GYAZO_TOKEN="$(...)"` だと終了コードが `export` の 0 になり、読み出しに失敗しても後続が実行される。

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

返る `url` (`https://i.gyazo.com/<id>.webp`) をそのまま貼る。

`desc` は `observe` の応答と git から組み立て (手で書かない)、画像だけ見て疑問に思うことに絞る。`metadata_is_public=true` で公開
されるので、リポジトリ相対パス・SHA・バージョンだけを載せ、手元の絶対パスやマシン名は入れない。
**`desc` は後から直せない** (直すには削除してアップロードし直し、URL が変わる) ので、アップロードする前に読み返す。

```
mokume <版> / stamp <刻印>
sketch: <リポジトリ相対パス> @ <SHA>
frame 128 (2.13s) / 800x600 / 59.9fps
```

同一バイトの画像には既存の id が返り、メタデータは更新されない。つまり同じ中身の絵には同じ URL が返る。

**この性質は当てにしない** (#3459)。同じピクセルの絵に別の URL が返って、撮り直すたびに全件の URL が変わった。リファレンス (`make example-shots`) はもう頼っておらず、記録の `image=` (ピクセルのハッシュ) でアップロードし直すかを決める。

### 落ちているかを見分ける

**upload が通っても URL が読めるとは限らない** ([#1294](https://github.com/mokume-metal/mokume/issues/1294)
は「貼ったつもりでリンクが切れている」形で現れた)。返った URL を必ずリクエストする:

```bash
curl -sI "$GYAZO_URL" -o /dev/null -w '%{http_code}\n'   # 200 でなければ退避路へ
```

200 でなければ、upload 自体が失敗したときも含め、指示を待たずに [fallback.md](fallback.md) へフォールバックする。
HEAD で足りるのは `i.gyazo.com` がリダイレクトを挟まず画像を返すからで、フォールバックの URL には別のリクエストの方法が要る。

## 貼る

**コードは GitHub 側に持つ** (`desc` は直せず、画像からも読めない。Gyazo には画像から離れず直す必要の生じない事実だけを置く)。リポジトリにあるコードは行範囲つきの
パーマリンクで指す。証跡のための使い捨てスケッチだけ `<details>` に全文を入れ、1 ファイルに収める —
収まらないなら使い捨てではなく、リポジトリに入れるべきものである。

before / after は表で並べ、両方に同じ `width` を書く。素の `![]()` だと原寸の差 (静止画は `observe` の解像度、
アニメーションは 720px) がそのまま大小になる ([#371](https://github.com/mokume-metal/mokume/issues/371))。揃えるのは
幅の側で、書き出しの `scale` ではない。単独で貼る絵は原寸のままでよい。

```markdown
| before (main) | after (this PR) |
| --- | --- |
| <img src="https://i.gyazo.com/<id>.png" width="480"> | <img src="https://i.gyazo.com/<id>.png" width="480"> |
```

アニメーションには撮影範囲と意図を文で添える: 何を撮ったか (`observe` で撮ったスケッチと条件、またはウィンドウ)・どの操作の何秒間か・
どこを見てほしいか。フレームを人が後から検証する代わりの記録である (「守ること」)。

**通常の経路で貼ったら camo 側を確認する。** camo が途中で切ったものはキャッシュに残り、Gyazo の URL を直接
叩いても、貼った本人の画面で見ても (どちらを取得するかはエッジ次第) 気付けない。貼った本文から camo URL を取り、何度か叩いて原本と同じ長さが返るかを見る:

```bash
gh api repos/mokume-metal/mokume/pulls/<N> -H 'Accept: application/vnd.github.html+json' --jq .body_html \
  | grep -oE 'https://camo\.githubusercontent\.com/[a-f0-9]+/[a-f0-9]+' | sort -u \
  | while read -r u; do
      for _ in 1 2 3; do curl -sS -o /dev/null -w "%{size_download} " "$u"; done; echo " $u"
    done
```

- 貼った直後は `body_html` が camo 化前を返す (20 秒ほど)。**取れた URL の数が貼った絵の数と合うか**を先に
  見る ([#374](https://github.com/mokume-metal/mokume/issues/374))
- 長さが違えば、先に小さくしてからアップロードし直して URL を変える (camo のキャッシュは消せず、同じバイトなら同じ id が返る)
- フォールバックで貼ったものは camo を通らないので要らない ([fallback.md](fallback.md) の「確認」)

## 守ること

- **before / after は `cmp -s before.png after.png` で同じでないことを確かめる。** 同じなら前のバージョンが応答した
  疑いがある (「撮り終えたら止める」)
- **アップロードは外部への送信である。** 送る前に写り込み (他アプリ・通知・手元のパス・秘密) を確かめ、
  判断がつかなければ聞く。フォールバックには削除する手段が無いので、そちらではこれが唯一の防壁になる
- アニメーションのフレームは読み込んで検証しない (コストが高く、写り込みの確率に見合わない)。代わりに撮影範囲と意図を書く
- 証跡はリポジトリにコミットしない (`scripts/check-no-binaries.sh` が拒否する)

## うまくいかないとき

| 症状 | 対処 |
| --- | --- |
| before / after が同じ・撮り直しても変わらない | 前のバージョンが動いている。`bash scripts/orphan-processes.sh` で終了させて撮り直す (「撮り終えたら止める」) |
| `observe` が「走っているスケッチが応えませんでした」 | 案内が「ディレクトリをこの呼び出しで作った」なら起動し直すだけ。「ディレクトリは前からあった」ならそもそも実行されていない |
| 貼った絵が出ない / 途中までしか動かない | camo で詰まっている (5MB 超で 404、手前でも途中で切れたものがキャッシュに残る)。小さくしてアップロードし直し、貼り直す (「貼る」の確認) |
| アニメーションに 16px の段差・淡い階調が消える | `-mixed` / `-lossy` でエンコードしている。可逆でエンコードし直す |
| アップロードし直したのに `desc` が変わらない / 自分にしか見えない | 同一バイトには既存の id が返り更新されない / `metadata_is_public=true` が要る |
| `unauthorized` | トークンを作り直す (「前提」) |
| mp4 を貼りたい | 通常の経路には方法が無い (API が受け付けず、埋め込んでも展開されない)。フォールバックでは通るが既定は WebP |
| フォールバックでアップロードしたものがおかしい (404・302 / 403・入力欄が空) | [fallback.md](fallback.md) の「うまくいかないとき」 |
| ウィンドウが一覧に出ない・`could not create image from window`・一覧が空 | [window.md](window.md) の「うまくいかないとき」 |

写り込みに後から気付いたら、通常の経路では削除して貼り直すまで面倒を見る (permalink が 404 になり、貼った先の画像も消える)。
フォールバックには削除する手段が無い ([fallback.md](fallback.md))。

```bash
GYAZO_TOKEN="$(eval "$MOKUME_GYAZO_TOKEN_CMD")" && curl -s -X DELETE \
  -H "Authorization: Bearer ${GYAZO_TOKEN}" https://api.gyazo.com/api/images/<image_id>
```

## 前提

フォールバックに要るもの (有人のセッションとブラウザのツール。秘密は要らない) は [fallback.md](fallback.md) の「前提」。

- **エンコードのツール**: `img2webp` (`brew install webp`) と `ffmpeg`
- **Gyazo のアクセストークン**: https://gyazo.com/oauth/applications でアプリを登録すると developer ページで
  発行できる (OAuth フローは要らない)。`MOKUME_GYAZO_TOKEN_CMD` へ「トークンを標準出力に出すコマンド」を渡し、
  手元の秘密管理から読ませる。**値も保管場所もリポジトリに書かず、値そのものを環境変数にも置かない**
- **ウィンドウの一覧 (経路 B)**: Gyazo の MCP サーバー (開発者向けプレビュー版で、仕様が変わることがある)
- **セッション**: 無人でも通る (隔離 worktree のサブエージェントは「アップロードする」の冒頭)
- **Claude Code 以外**: コマンドと規律は共通。`allowed-tools` の MCP 名は Claude Code の接続名で、接続を
  提供する設定ではない。ウィンドウの一覧が無くても経路 A で進め、使えないツールがあるときに公開済みと扱わない
