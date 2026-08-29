---
name: gyazo-evidence
description: 描画結果・動きが変わる変更を PR / Issue に記録するとき、スケッチの絵や窓の様子を Gyazo へ上げて URL を得る。撮る経路・宛先ごとの形式・出所の残し方を扱う。Use when attaching visual evidence to a pull request or issue, when a drawing or motion change needs before/after images, when capturing an animated WebP or GIF, or when embedding images in docs.
allowed-tools: "mcp__gyazo-mac__gyazo_list_capturable_windows"
---

<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# Gyazo で視覚証跡を残す

**何を載せるかの規律は AGENTS.md 「描画に影響する変更」が正典**で、ここは手順だけを持つ。

手順が要るのは、証跡がこのリポジトリでは添え物ではないからである。CI は描画を走らせられない
([#180](https://github.com/mokume-metal/mokume/issues/180)) ので、**緑は「描けている」を意味しない**。
PR に貼られた絵が描画の唯一の検証記録になり、squash merge でブランチが消えた後には足せない。

> **人がこれを読んでいるなら、たいていここは要らない。** Issue / PR の入力欄へ画像を落とせば
> GitHub が保管して URL を返す — アカウントもトークンも要らず、そちらの方が早い。
> この文書が扱うのは**エージェントの経路**である。直接アップロードには API が無く、
> エージェントには押せる入力欄も無いため、代わりに Gyazo へ上げて URL を貼る。

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
> (`FrameObserver.makeIfEnabled`)。後から作っても走っているスケッチは拾わず、
> 「走っているスケッチが見つかりません」と返る。このとき `watch` の起動を促す案内が出るが、
> **`watch` を起動しても区画が無ければ同じように失敗する** — 直すのは順序である。

窓口の `observe` が返すのは、絵の場所と内訳 (フレーム番号・時刻・大きさ・絵の要約・走らせている
重さ・スケッチが差し出した値・**版の刻印**)。この内訳がそのまま出所の記録になるので、捨てずに取っておく。

窓口を立てずに区画へ直接置いてもよい。`.mokume/observe/request.json` へ `{"id": "<毎回変える>"}` を
原子的に置き、`.mokume/observe/report.json` の `id` が一致するまで待つ (仕様は
`Schemas/observe-request.schema.json`)。

### 動きも A で撮る

**識別子を変えながら要求を置き、`report.json` の `id` が一致したら `image` が指す絵を退避する** —
これを繰り返せば連番がそのまま手に入る。B のように録画から起こす必要は無い。要求に `scale` を
添えると書き出しの時点で縮むので、束ねる前の縮小も要らない。

```bash
python3 - <スケッチの場所>/.mokume/observe frames 70 0.5 <<'CAPTURE'
import json, os, pathlib, shutil, sys, time

facet, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
rounds, scale = int(sys.argv[3]), float(sys.argv[4])
out.mkdir(parents=True, exist_ok=True)
previous = None

for index in range(1, rounds + 1):
    identifier = f"f{index:04d}"
    temporary = facet / ".request.json.tmp"           # 原子的に置く
    temporary.write_text(json.dumps({"id": identifier, "scale": scale}))
    os.replace(temporary, facet / "request.json")

    taken, limit = None, time.time() + 1.5
    while time.time() < limit:                        # 壁時計ではなく識別子の一致で完了を知る
        try:
            report = json.loads((facet / "report.json").read_text())
            if report.get("id") == identifier and report.get("image"):
                taken = shutil.copy(facet / report["image"], out / f"f.{index:04d}.png")
                break
        except Exception:
            pass
        time.sleep(0.01)

    if taken is None and previous:                    # 返らなかったら直前の絵を置く
        shutil.copy(previous, out / f"f.{index:04d}.png")
    previous = taken or previous
CAPTURE
```

置き方と待ち方は `scripts/check-observation-roundtrip.sh` と同じで、**形式の正典は `Schemas/` の
`observe-request` / `observe-report`** である (絵のファイル名も応答の `image` が名乗る — 決め打ちしない)。

> **応答が返らなかった回は直前の絵で埋める。抜けを詰めない。** 詰めると「面が黙った」ことが動きから
> 消えてしまい、それ自体が見せたい事象であることがある
> ([#310](https://github.com/mokume-metal/mokume/pull/310#issuecomment-5452377415) が実例 — 窓を畳んだ後に
> 絵が凍るか回り続けるかの差が、70 枚のうち異なる絵の枚数として出た)。

**採れる間隔は一定ではない** — 1 枚ごとに応答を待つためである。実時間との対応が要るなら、退避と一緒に
`report.json` の `frame` と `time` も控えておく。

## B. 窓を撮る

窓の一覧を `gyazo_list_capturable_windows` で取る。**得た id はそのまま `screencapture` に渡せる。**

```bash
screencapture -l <windowId> -o shot.png       # 静止画 (窓の影を含めない)
screencapture -l <windowId> -V 5 motion.mov   # 5 秒の録画
```

**全画面 (`-l` を省く形) は撮らない** — 他アプリ・通知・手元のパスが写る。

## 動きを束ねる — 形式は宛先で決まる

| 宛先 | 静止画 | 動き | 使えないもの |
| --- | --- | --- | --- |
| PR / Issue | PNG | **WebP** | mp4 |
| DocC | PNG | **GIF** | WebP / mp4 |

PR / Issue で WebP を使うのは、同じ絵で GIF より小さく、色数が多くても劣化しないため。
**DocC は WebP を警告も出さずに落とす**ので、そちらへ出すものだけ GIF にする
(このリポジトリにまだ DocC が無いため、DocC 側は**未検証**)。

**A は連番がそのまま手に入る**ので、束ねる所から始める。B は録画なので、まず連番へ起こす。

```bash
# 録画から連番へ (B のみ・幅 720 / 15fps が目安)
ffmpeg -y -i motion.mov -vf "fps=15,scale=720:-1:flags=lanczos" frames/f.%04d.png

# PR / Issue へ出す — WebP
img2webp -loop 0 -mixed -d 67 frames/f.*.png -o motion.webp

# DocC へ出す — GIF (パレットを作ってから通す)
ffmpeg -y -i motion.mov -vf "fps=15,scale=720:-1:flags=lanczos,palettegen" palette.png
ffmpeg -y -i motion.mov -i palette.png \
  -lavfi "fps=15,scale=720:-1:flags=lanczos,paletteuse" -loop 0 motion.gif
```

`-d` はフレーム間隔 (ミリ秒。15fps なら 67)。`-mixed` はフレームごとに可逆 / 非可逆を選ばせる指定で、
**微細な差分を見せる証跡では `-lossless`** を使う (サイズは増えるが 1 ビットも劣化しない)。

## 上げる

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

## 貼る

**コードは Gyazo ではなく GitHub 側に持つ。** `desc` は後から直せず、貼った画像からも読めないためである
(Gyazo 側に置くのは、画像から離れず・直す必要が生じない事実だけ)。

- リポジトリにあるコードは **行範囲つきの恒久リンクで指す** — 写さないので長さの問題が起きない
- 証跡のための使い捨てスケッチだけ `<details>` に全文を入れる。**1 ファイルに収める** — 収まらないなら、
  それは使い捨てではなくリポジトリに入れるべきものである

before / after は表で並べる。

```markdown
| before (main) | after (this PR) |
| --- | --- |
| ![before](https://i.gyazo.com/<id>.png) | ![after](https://i.gyazo.com/<id>.png) |
```

**動きには撮影範囲と意図をテキストで添える。** フレームを人が後から検める代わりの記録なので、
何を撮ったか (A なら観測したスケッチと条件・B ならどの窓)・どの操作の何秒間か・どこを見てほしいかを書く。

## 守ること

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
- **写り込みに後から気付いた / 消したい**

  ```bash
  GYAZO_TOKEN="$(eval "$MOKUME_GYAZO_TOKEN_CMD")" && curl -s -X DELETE \
    -H "Authorization: Bearer ${GYAZO_TOKEN}" https://api.gyazo.com/api/images/<image_id>
  ```

  permalink が 404 になる。**貼った先の画像も消えるので、貼り直しまで面倒を見る**
- **mp4 を貼りたい** — 経路が無い。アップロード API が受け付けず、埋め込んでも展開されない。動きは
  WebP (PR / Issue) か GIF (DocC) にする
- **観測が「走っているスケッチが見つかりません」と返る** — 区画を起動より後に作っている (A の順序を見る)。
  一度走らせてしまったら、止めて・区画を作って・起動し直す
- **窓の一覧に目的の窓が出ない** — 一覧が返すのは**いま画面に出ている窓**である。背面で起動した
  (`nohup` 等) スケッチや、最小化・別の Space にある窓は出てこない。前に出してから取り直す
- **窓の一覧が空 / 撮れない** — 画面収録の許可が要る。**付与は GUI 操作なので代行せず頼む**
- **`unauthorized`** — トークンを作り直す (https://gyazo.com/oauth/applications)。OAuth フローは要らず、
  developer ページで出せる 1 本でよい

## 前提

- `img2webp` (`brew install webp`) と `ffmpeg`
- **Gyazo のアクセストークン。** https://gyazo.com/oauth/applications でアプリを登録すると出せる
  (OAuth フローは要らず、developer ページで出せる 1 本でよい)。環境変数 **`MOKUME_GYAZO_TOKEN_CMD`** へ
  「トークンを標準出力に出すコマンド」を渡し、手元の秘密管理から読ませる — 値そのものを環境変数に置かない
- 窓の一覧には Gyazo の MCP サーバーが要る (開発者向けプレビュー版・公式サポート対象外で、
  仕様が変わることがある)
