<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 退避路 — Gyazo が落ちているときに GitHub へ直接上げる

**本線 (Gyazo) が落ちていると分かったときにだけ読む。** 判定は [SKILL.md](SKILL.md) の
「落ちているかを見分ける」が持ち、そこで 200 が返らなければ**指示を待たずに**ここへ落ちる。

退避路があるのは、上げ先が 1 本だと**そこが落ちた瞬間に描画の PR を出せなくなる**からである
([#1294](https://github.com/mokume-metal/mokume/issues/1294) で 178 本が一斉に 404 になった)。
GitHub には添付の API が無いが、**ブラウザを操作できるセッションなら人間と同じ経路を通せる**
([#1306](https://github.com/mokume-metal/mokume/issues/1306) で実測)。

撮り方・束ね方・`desc` の組み方・貼り方は本線と同じで、[SKILL.md](SKILL.md) のとおりに進める。
動きの形式も本線と同じ WebP でよい (束ね直しは要らない)。ここが持つのは、**上げ方と、上げた後の
確かめ方の違い**だけである。

## 前提

**退避路は秘密を 1 つも要らない代わりに、有人のセッションを要求する。**

- **ブラウザを操作できる有人のセッション**で、GitHub にサインイン済みであること
- **ページの `input[type=file]` へファイルを渡せるブラウザ道具** (file upload)。クリップボードは使わない
- 束ねる道具は本線と同じ (SKILL.md の「前提」)

**無人セッション (`MOKUME_UNATTENDED=1`) ではこの経路は使えない。** ブラウザを操作できないためである。
Gyazo も落ちていて証跡を残せないときは、**そのことを PR 本文に書いて Draft に落とし、有人のセッションへ返す** —
絵の無い描画 PR は `drawing-evidence` が赤で差し戻すので、黙って進めても merge できない。

隔離 worktree のサブエージェントは、本線と同じくここも打たない。材料を親へ返す (SKILL.md の「上げる」節の頭)。

## 上げる

GitHub には添付の API が無い。REST にも GraphQL にも口が無いので、この経路は**ブラウザを操作できる
セッションでしか通らない**。通る形は 1 つだけである — **ページの `input[type=file]` へ
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
> ([#1332](https://github.com/mokume-metal/mokume/issues/1332))。WebP はコメントの中でも動いて描かれた。
> **動きを束ね直す必要は無い** — 本線と同じ WebP をそのまま出せる。

### 投稿して公開する

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
> 4. **`gh pr edit` で書いたなら、赤い `drawing-evidence` の run を打ち直す** (`gh run rerun <run-id> --failed`。run が終わってから)。本文の編集は新しい run を起こして判定を付け直すが、PR 作成時の run の赤い `ci-gate` は残って必須チェックを赤のままにする (`.github/workflows/ci.yml` の `ci-gate` の上のコメント)

### 参照の面には使わない

**退避路が効くのは PR / Issue の一回限りの証跡までで、参照の面 (`make example-shots`) には使わない。**
あちらは「同じ中身の絵には同じ URL が返る」という Gyazo の冪等性を借りており、**撮り直して URL が
変わったかがそのまま絵が変わったかの判定**になっている (理由: [ADR-0027](../../../docs/decisions/0027-readable-surfaces.md)
決定 2)。GitHub の添付は同じ絵でも毎回別の URL を返すので、この判定が成り立たない。参照の面は本線が戻るまで待つ。

### 通らない道 — 試して時間を落とさないために

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

## 大きさの上限

**退避路 (GitHub) は camo を通らない。** `github.com/user-attachments/…` は GitHub 自身の面なので、
markdown は素の `<img src>` のまま出す ([#1306](https://github.com/mokume-metal/mokume/issues/1306) で実測)。
したがって本線の 4MB の目安も、途中で切られる壊れ方も**こちらには無い**。代わりに効くのは GitHub の
受け入れ上限で、**画像と GIF が 10MB・動画が 10MB (有料プランのリポジトリは 100MB)・その他が 25MB** である。

## 検算

**投稿した後に、GET でリダイレクトを追い、原本とバイト数を突き合わせる** (投稿前は 404 のままなので、
確かめるのは必ず投稿の後)。本線で貼った後に打つ camo の検算は、こちらには要らない — camo を通らないので
切られる余地が無い。

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

## うまくいかないとき

- **上げた絵が、投稿したのに 404** — **公開は少し遅れて効く。** まず数十秒おいて引き直す
  ([#1332](https://github.com/mokume-metal/mokume/issues/1332) で実測)。それでも 404 なら
  **その URL を含むコメントをまだ投稿していない** — 貼った時点では公開されず、上げた本人のセッションから
  しか読めない。**PR 本文へ書いただけでも公開されない**ので、コメントとして投稿してから引き直す。
  **未投稿を名乗るのは 404 だけ**である (下の行)
- **検算が 302 / 403 を返す** — **添付は公開されていて、打ち方が合っていないだけである。**
  `-sI` / `-s` は署名付き S3 への転送 (302) が返ったところで止まっており、`-sIL` は presigned URL が
  GET 用に署名されているため HEAD が弾かれている (403)。`-sL` で GET で追い直す (「検算」)。
  **これを「まだ公開されていない」と読んで Draft に落とさない** — 上げ先が 2 本とも塞がったように
  見えて、描画 PR が 1 本も出せなくなる ([#1310](https://github.com/mokume-metal/mokume/issues/1310))
- **貼っても入力欄が空のまま (エラーも出ない)** — クリップボード経由で運ぼうとしている。
  合成したキー入力はブラウザの貼り付けコマンドを起こさない (「通らない道」)。**`input[type=file]` へ
  渡す形**に置き換える
- **注入した入力欄が `find` で見つからない** — `aria-label` を付けていない。画面外や
  `display:none` にも置かない (拾えなくなる)
- **貼った動きが 1 枚の静止画になっている / 形式が受け付けられない** — 上がったものは
  **原本とバイト単位で一致する**ので、この経路では起こらない。起きたなら渡したファイルのほうを疑う
  (`shasum -a 256` で原本と突き合わせる)
- **ブラウザが繋がらない** — 退避路はブラウザを操作できるセッションでしか通らない。Gyazo も
  落ちているなら証跡は残せないので、**PR にそう書いて Draft に落とし、有人のセッションへ返す**
- **写り込みに後から気付いた** — **こちらには消す口が無い。** 本文から URL を外しても
  添付そのものは残り、URL を知っていれば引ける。**だから退避路では「送る前に確かめる」が唯一の防壁**である
  (SKILL.md の「守ること」)。それでも出してしまったら、リポジトリの外に出た秘密として人に報告する
- **mp4 を貼りたい** — 退避路では通る。`accept` に載っており、83202 B のものが SHA-256 一致で上がった
  ([#1332](https://github.com/mokume-metal/mokume/issues/1332))。ただし**動きの既定は WebP のまま**でよい
  (本線と同じものをそのまま出せる)
