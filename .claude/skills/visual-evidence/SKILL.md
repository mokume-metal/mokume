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

何を載せるかの規律は AGENTS.md「描画に影響する変更」が正典で、ここは手順だけを持つ。CI は描画を走らせられない
([#180](https://github.com/mokume-metal/mokume/issues/180)) ので、**PR に貼った絵が描画の唯一の検証記録になり、
squash merge の後には足せない。** 人なら入力欄へ画像を落とすだけでよく、この文書はエージェントの経路を扱う。

| 場面 | 読む先 |
| --- | --- |
| スケッチの絵を撮る (既定) | この文書 |
| 窓・GUI・操作そのものを撮る | [window.md](window.md) |
| Gyazo が落ちている (「落ちているかを見分ける」で 200 が返らない) | [fallback.md](fallback.md) |
| 複数の変更を人が確認する報告へ束ねる | [report.md](report.md) |

**撮影と送信は分ける。** 手元に落としてから上げ、外部へ送る前に写り込みを検める。Gyazo の MCP の
「撮って即座に上げる」道具は使わず、窓の一覧だけを取る (`allowed-tools` がそれだけなのはこのため)。

## 撮る — スケッチの絵 (経路 A)

観測で撮れば、同じ条件で撮り直せ、他アプリの映り込みも窓の位置への依存も無い。**区画を作ってから起動する** —
観測は起動の瞬間に区画があるときだけ有効になる (`FrameObserver.makeIfEnabled`)。

```bash
mkdir -p <スケッチの場所>/.mokume/observe    # 起動より先に作る
swift run mokume-cli watch <スケッチの場所>  # 窓が出る
swift run mokume-cli mcp <スケッチの場所>    # エージェントの窓口を立てる
```

順を逆にすると、窓口が「区画はこの呼び出しで作ったので、起動し直してください」と返す。区画は作り直さず、
スケッチだけ起動し直す ([#227](https://github.com/mokume-metal/mokume/issues/227))。

窓口の `observe` は絵の場所と内訳 (フレーム番号・時刻・大きさ・絵の要約・重さ・スケッチが差し出した値・
版の刻印) を返す。**内訳はそのまま出所の記録になるので取っておく。** 刻印 (`stamp`) は `watch` で起こしたときだけ
入り (`Sources/MokumeCLI/WatchSession.swift`)、`run` では黙って落ちる。刻印が要るなら `watch` で起こす — `run` の出所は、どの版を組んだかという
撮った本人の記録しか名乗れない ([#1091](https://github.com/mokume-metal/mokume/issues/1091))。
窓口を立てず、`.mokume/observe/request.json` へ `{"id": "<毎回変える>"}` を原子的に置いて
`report.json` の `id` が一致するまで待ってもよい (置き方は `scripts/observe_lib.py` の `place`)。

### 動きを撮る

識別子を変えながら要求を置き、応答の `image` が指す絵を退避すれば連番になる。`scale` を添えると
書き出しの時点で縮む。**リポジトリの根から打つ** (`scripts/observe_lib.py` を読むため)。

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

- **置き方と待ち方はここへ写さない。** 実装は `scripts/observe_lib.py` の 1 つ、形式の正典は `Schemas/` の
  `observe-request` / `observe-report` ([#817](https://github.com/mokume-metal/mokume/issues/817))。
  絵のファイル名も応答の `image` に従い、決め打ちしない
- **応答が返らなかった回は直前の絵で埋め、詰めない。** 「面が黙った」こと自体が見せたい事象のことがある
  ([#310](https://github.com/mokume-metal/mokume/pull/310#issuecomment-5452377415))

### 撮り終えたら止める

**走らせたままにすると、次の撮影を前の版が答える。** 区画はディレクトリで決まるので、同じ場所で
before → after と撮ると、1 回目のスケッチが 2 回目にも答える。応答も絵も正常で、
間違っているのは「どの版が描いたか」だけである ([#1091](https://github.com/mokume-metal/mokume/issues/1091))。

起こした道具の PID へ素の `kill` を打つ。`run` も `watch` も `SIGTERM` / `SIGHUP` をスケッチへ渡してから
終わり ([#1193](https://github.com/mokume-metal/mokume/issues/1193))、`swift run` は exec するので `$!` のままでよい。

```bash
swift run mokume-cli watch <スケッチの場所> & tool=$!   # PID を控えてから撮る
# … 撮る …
kill "$tool"                                            # 配下のスケッチごと畳まれる
```

| 効かない撃ち方 | 理由 |
| --- | --- |
| `kill -9` (SIGKILL) | 渡す受け口が走らない。スケッチは `ppid=1` の孤児として残り、観測に答え続ける |
| プロセスグループごと (`kill -TERM -<pgid>`) | スケッチは `Process` が起こした自分のグループに居るので当たらない |

控え損ねたら `bash scripts/orphan-processes.sh` が PID を出所つきで出す。`pkill -f` で掃くときは、`ps` が
見せる起動時のパス (`/tmp/…`) と `resolve()` した綴り (`/private/tmp/…`) が割れるので、
`pkill -f '<スケッチ名>/.build'` のように綴りの割れない末尾側で照合する (外すと 1 つも当たらず全部残る)。

## 束ねる — 形式は宛先で決まる

| 宛先 | 静止画 | 動き | 使えないもの |
| --- | --- | --- | --- |
| PR / Issue (本線 = Gyazo) | PNG | **WebP** | mp4 |
| PR / Issue (退避路 = GitHub) | PNG | **WebP** | — (mp4 も通る) |
| 参照の面 | PNG | **GIF** | WebP / mp4 |

WebP は GIF より小さく、色数が多くても劣化しない。上げ先が切り替わっても束ね直しは要らない。
A の連番は採れる間隔が揺れるので、`-d` (表示時間、ミリ秒) を `timing.json` の間隔から 1 枚ずつ決める。
**等間隔で束ねると、スケッチが速さを変えていないのに速さが変わって見える** ([#370](https://github.com/mokume-metal/mokume/issues/370))。

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

**可逆のまま束ねる。** `-mixed` や `-lossy` を付けると淡い階調が 16px の段差に潰れ、正しく描けた絵が
壊れて見える ([#369](https://github.com/mokume-metal/mokume/issues/369))。証跡の価値は、元の絵に無いものが
足されていないことにある。

**本線は 4MB を目安に収める。** 詰まるのは Gyazo (40MB) ではなく GitHub の camo である。5,242,880 バイトを
超えると `Content length exceeded` で 404 になり、その手前でも途中で切られた側が 1 年キャッシュされる
(実測では 3.7MB は無事、4.6MB が壊れた — [#369](https://github.com/mokume-metal/mokume/issues/369))。
超えたら可逆の枠内で落とす — `-near_lossless` は可逆圧縮の中で値を丸めるだけで、元に無いものを足さない。
それでも収まらなければ短く / 小さくする。`-mixed` へ戻る段は作らない
(退避路は camo を通らず、上限も別 — [fallback.md](fallback.md) の「大きさの上限」)。

```bash
img2webp -loop 0 -near_lossless 60 -d 67 frames/f.*.png -o motion.webp   # 最大誤差 2 階調
img2webp -loop 0 -near_lossless 40 -d 67 frames/f.*.png -o motion.webp   # 最大誤差 4 階調
```

経路 A では `-d 67` で等間隔にせず、上の BUNDLE の `arguments` に `-near_lossless 60` を足す。

### 参照の面へ出す GIF

参照の面は WebP を警告も出さずに落とし、参照ごと本文から消える (ビルドは緑)。mp4 は面の道具が `@Video` で
扱えるが、上げる経路が無い。だからそちらへ出す動きだけ GIF にする
(理由: [ADR-0027](../../../docs/decisions/0027-readable-surfaces.md) 決定 2)。パレットを作ってから通す (例は録画 `motion.mov` から):

```bash
ffmpeg -y -i motion.mov -vf "fps=15,scale=720:-1:flags=lanczos,palettegen" palette.png
ffmpeg -y -i motion.mov -i palette.png \
  -lavfi "fps=15,scale=720:-1:flags=lanczos,paletteuse" -loop 0 motion.gif
```

## 上げる

**隔離されたサブエージェント (`isolation: "worktree"` など、ツール名によらない) は、撮る・束ねる・`desc` を
組むまでで止まる。** ここから下 (上げる・見分ける・検算・公開の投稿・消す) は親が打ち、親が無人でも分担は
変わらない (通せなければ [fallback.md](fallback.md) の「前提」のとおり Draft に落とす)。親へは、上げるファイルの
絶対パス・`title`・`desc` (本文か `desc.txt` の絶対パス)・宛先の番号・撮影範囲と意図を、worktree の外で親から
読める所に Issue 番号で分けて置いて返す (隔離 worktree は変更が無ければ消え、一時領域は兄弟と共有されうる)。
ここの手順はガードに止められるが、**止められた行をスクリプトへ移す・綴りを割るなどして通さない** — 検証
できないコマンドを通さない守りを外すことになる。親は同じ行をそのまま打てる ([#1494](https://github.com/mokume-metal/mokume/issues/1494))。

### 本線 — Gyazo へ上げる

トークンは `MOKUME_GYAZO_TOKEN_CMD` から読む (「前提」)。代入から始めて `&&` で繋ぐ —
`export GYAZO_TOKEN="$(...)"` だと終了コードが `export` の 0 に化け、読み出しに失敗しても後続が走る。

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

`desc` は観測の応答と git から組み (手で書かない)、画像だけ見て疑問に思うことに絞る。`metadata_is_public=true` で公開
されるので、リポジトリ相対パス・SHA・版だけを載せ、手元の絶対パスやマシン名は入れない。
**`desc` は後から直せない** (直すには消して上げ直し、URL が変わる) ので、上げる前に読み返す。

```
mokume <版> / stamp <刻印>
sketch: <リポジトリ相対パス> @ <SHA>
frame 128 (2.13s) / 800x600 / 59.9fps
```

同一バイトの画像には既存の id が返り、メタデータは更新されない。つまり同じ中身の絵には同じ URL が返る。

### 落ちているかを見分ける

**upload が通っても URL が読めるとは限らない** ([#1294](https://github.com/mokume-metal/mokume/issues/1294)
は「貼ったつもりで死んでいる」形で現れた)。返った URL を必ず引く:

```bash
curl -sI "$GYAZO_URL" -o /dev/null -w '%{http_code}\n'   # 200 でなければ退避路へ
```

200 でなければ、upload 自体が失敗したときも含め、指示を待たずに [fallback.md](fallback.md) へ落ちる。
HEAD で足りるのは `i.gyazo.com` が転送を挟まず画像を返すからで、退避路の URL には別の打ち方が要る。

## 貼る

**コードは GitHub 側に持つ** (`desc` は直せず、画像からも読めない。Gyazo には画像から離れず直す必要の生じない事実だけを置く)。リポジトリにあるコードは行範囲つきの
恒久リンクで指す。証跡のための使い捨てスケッチだけ `<details>` に全文を入れ、1 ファイルに収める —
収まらないなら使い捨てではなく、リポジトリに入れるべきものである。

before / after は表で並べ、両方に同じ `width` を書く。素の `![]()` だと原寸の差 (静止画は観測の解像度、
動きは 720px) がそのまま大小になる ([#371](https://github.com/mokume-metal/mokume/issues/371))。揃えるのは
幅の側で、書き出しの `scale` ではない。単独で貼る絵は原寸のままでよい。

```markdown
| before (main) | after (this PR) |
| --- | --- |
| <img src="https://i.gyazo.com/<id>.png" width="480"> | <img src="https://i.gyazo.com/<id>.png" width="480"> |
```

動きには撮影範囲と意図を文で添える: 何を撮ったか (観測したスケッチと条件、または窓)・どの操作の何秒間か・
どこを見てほしいか。フレームを人が後から検める代わりの記録である (「守ること」)。

**本線で貼ったら camo 側を検算する。** camo が途中で切った側はキャッシュに焼かれ、Gyazo の URL を直接
叩いても、貼った本人の画面で見ても (どちらを引くかはエッジ次第) 気付けない。貼った本文から camo URL を取り、何度か叩いて原本と同じ長さが返るかを見る:

```bash
gh api repos/mokume-metal/mokume/pulls/<N> -H 'Accept: application/vnd.github.html+json' --jq .body_html \
  | grep -oE 'https://camo\.githubusercontent\.com/[a-f0-9]+/[a-f0-9]+' | sort -u \
  | while read -r u; do
      for _ in 1 2 3; do curl -sS -o /dev/null -w "%{size_download} " "$u"; done; echo " $u"
    done
```

- 貼った直後は `body_html` が camo 化前を返す (20 秒ほど)。**取れた URL の数が貼った絵の数と合うか**を先に
  見る ([#374](https://github.com/mokume-metal/mokume/issues/374))
- 長さが違えば、先に小さくしてから上げ直して URL を変える (camo のキャッシュは消せず、同じバイトなら同じ id が返る)
- 退避路で貼ったものは camo を通らないので要らない ([fallback.md](fallback.md) の「検算」)

## 守ること

- **before / after は `cmp -s before.png after.png` で同じでないことを確かめる。** 同じなら前の版が答えた
  疑いがある (「撮り終えたら止める」)
- **上げることは外部への送信である。** 送る前に写り込み (他アプリ・通知・手元のパス・秘密) を確かめ、
  判断がつかなければ聞く。退避路には消す口が無いので、そちらではこれが唯一の防壁になる
- 動きのフレームは読み込んで検めない (高くつき、写り込みの確率に見合わない)。代わりに撮影範囲と意図を書く
- 証跡はリポジトリにコミットしない (`scripts/check-no-binaries.sh` が弾く)

## うまくいかないとき

| 症状 | 対処 |
| --- | --- |
| before / after が同じ・撮り直しても変わらない | 前の版が生きている。`bash scripts/orphan-processes.sh` で落として撮り直す (「撮り終えたら止める」) |
| 観測が「走っているスケッチが応えませんでした」 | 案内が「区画をこの呼び出しで作った」なら起動し直すだけ。「区画は前から在った」ならそもそも走っていない |
| 貼った絵が出ない / 途中までしか動かない | camo で詰まっている (5MB 超で 404、手前でも途中切断が焼き付く)。小さくして上げ直し、貼り直す (「貼る」の検算) |
| 動きに 16px の段差・淡い階調が消える | `-mixed` / `-lossy` で束ねている。可逆で束ね直す |
| 上げ直したのに `desc` が変わらない / 自分にしか見えない | 同一バイトには既存の id が返り更新されない / `metadata_is_public=true` が要る |
| `unauthorized` | トークンを作り直す (「前提」) |
| mp4 を貼りたい | 本線には経路が無い (API が受け付けず、埋め込んでも展開されない)。退避路では通るが既定は WebP |
| 退避路で上げたものがおかしい (404・302 / 403・入力欄が空) | [fallback.md](fallback.md) の「うまくいかないとき」 |
| 窓が一覧に出ない・`could not create image from window`・一覧が空 | [window.md](window.md) の「うまくいかないとき」 |

写り込みに後から気付いたら、本線は消して貼り直しまで面倒を見る (permalink が 404 になり、貼った先の画像も消える)。
退避路には消す口が無い ([fallback.md](fallback.md))。

```bash
GYAZO_TOKEN="$(eval "$MOKUME_GYAZO_TOKEN_CMD")" && curl -s -X DELETE \
  -H "Authorization: Bearer ${GYAZO_TOKEN}" https://api.gyazo.com/api/images/<image_id>
```

## 前提

退避路に要るもの (有人のセッションとブラウザ道具。秘密は要らない) は [fallback.md](fallback.md) の「前提」。

- **束ねる道具**: `img2webp` (`brew install webp`) と `ffmpeg`
- **Gyazo のアクセストークン**: https://gyazo.com/oauth/applications でアプリを登録すると developer ページで
  出せる (OAuth フローは要らない)。`MOKUME_GYAZO_TOKEN_CMD` へ「トークンを標準出力に出すコマンド」を渡し、
  手元の秘密管理から読ませる。**値も在処もリポジトリに書かず、値そのものを環境変数にも置かない**
- **窓の一覧 (経路 B)**: Gyazo の MCP サーバー (開発者向けプレビュー版で、仕様が変わることがある)
- **セッション**: 無人でも通る (隔離 worktree のサブエージェントは「上げる」の頭)
- **Claude Code 以外**: コマンドと規律は共通。`allowed-tools` の MCP 名は Claude Code の接続名で、接続を
  供給する設定ではない。窓の一覧が無くても経路 A で進め、使えない道具があるときに公開済みと扱わない
