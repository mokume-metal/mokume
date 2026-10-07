<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# 退避路 — Gyazo が落ちているときに GitHub へ直接上げる

**本線 (Gyazo) が落ちていると分かったときにだけ読む。** 判定は [SKILL.md](SKILL.md) の
「落ちているかを見分ける」が持ち、200 が返らなければ指示を待たずにここへ落ちる。上げ先が 1 本だと、
そこが落ちた瞬間に描画の PR を出せなくなるためである
([#1294](https://github.com/mokume-metal/mokume/issues/1294) で 178 本が一斉に 404 になった)。

撮り方・束ね方・`desc` の組み方・貼り方は本線と同じで、動きも同じ WebP をそのまま出せる。
ここが持つのは、上げ方と、上げた後の確かめ方の違いだけである。

## 前提

**秘密は 1 つも要らない代わりに、有人のセッションを要求する。**

- ブラウザを操作できる有人のセッションで、GitHub にサインイン済みであること
- ページの `input[type=file]` へファイルを渡せるブラウザ道具 (file upload)
- 束ねる道具は本線と同じ (SKILL.md の「前提」)

**無人セッション (`MOKUME_UNATTENDED=1`) では使えない。** Gyazo も落ちていて証跡を残せないときは、
そのことを PR 本文に書いて Draft に落とし、有人のセッションへ返す — 絵の無い描画 PR は
`drawing-evidence` が赤で差し戻すので、黙って進めても merge できない。隔離 worktree のサブエージェントは
ここも打たず、材料を親へ返す (SKILL.md の「上げる」節の頭)。

## 上げる

GitHub には添付の API が (REST にも GraphQL にも) 無い。通る形は 1 つだけで、**ページの
`input[type=file]` へファイルを渡す** (クリップボードは経由しない — 下の「通らない道」)。

その入力欄が在るかは面で違う (2026-09-22 実測・[#1332](https://github.com/mokume-metal/mokume/issues/1332)):

| 面 | `input[type=file]` |
| --- | --- |
| **PR** のコメント欄 | **在る** — `id="fc-new_comment_field"`。`accept` は `.gif,.jpeg,.jpg,.mov,.mp4,.png,.svg,.webm,.webp,…` |
| **Issue** のコメント欄 (React の新 UI) | **無い** — 「Paste, drop, or click to add files」は `<button>` で、欄は押すまで DOM に現れない |

だから手順は「無ければ自分で置く」形にし、どちらの UI でも分岐なしで通す:

**1. 入力欄を用意する。** PR なら `fc-new_comment_field` をそのまま使う。無い面では注入する:

```javascript
const staging = document.createElement('input');
staging.type = 'file';
staging.id = 'mokume-evidence-input';
staging.setAttribute('aria-label', 'mokume evidence staging file input');  // find が拾えるように
staging.style.cssText = 'position:fixed;top:0;left:0;z-index:99999;background:#fff';
document.body.appendChild(staging);
```

**2. その欄へファイルを渡す** (ブラウザ道具の file upload。要素の参照は `find` で取る)。手元のバイト列を
ページへ運べるのはこの 1 手だけである。

**3. 注入した欄を使ったときは、コメント欄へ `paste` を合成して渡し直す** (`fc-new_comment_field` へ渡した
ときは GitHub 自身の受け口なので要らない):

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
動画は裸の URL 1 行である (`![]()` では囲まない)。

**5. 注入した欄を外し、下書きを空にしてタブを閉じる** (投稿はラッパー経由なので、欄の本文は捨てる)。

上がったものは原本とバイト単位で一致する (PNG 2 本・WebP・mp4 で SHA-256 まで一致し、WebP はコメントの中でも
動いた — [#1332](https://github.com/mokume-metal/mokume/issues/1332))。

### 投稿して公開する

**URL は投稿して初めて生きる。** 貼った時点では上げた本人のセッションからしか読めず、無認証では 404 である。
公開されるのは、その URL が新しく投稿されたコメントに現れたときで、**少し遅れて効く** (投稿直後の 404 は
「まだ」であって失敗ではない。数十秒おいて引き直す — [#1332](https://github.com/mokume-metal/mokume/issues/1332))。

```bash
bash scripts/comment.sh {issue,pr} <番号> --body-file <ファイル>
```

上げた欄と投稿先は別でよい。添付はスレッドに縛られないので、PR のコメント欄で上げたものを Issue へ投稿しても
公開される。

**PR 本文へ載せたいときも、先にコメントで投稿する。** `gh pr edit --body` で本文に書いても、本文の編集は
新しい投稿に数えられず 404 のままである ([#1306](https://github.com/mokume-metal/mokume/issues/1306))。
`drawing-evidence` が読むのは PR 本文なので、描画 PR ではこの順を守る:

1. コメント欄へ貼って URL を得る
2. **その URL を含むコメントを投稿する** (`scripts/comment.sh`) — ここで公開される
3. 同じ URL を PR 本文へ書く (`gh pr create --body-file` / `gh pr edit --body-file`。発言ではないのでラッパーは通さない)
4. **`gh pr edit` で書いたなら、赤い `drawing-evidence` の run を打ち直す** (`gh run rerun <run-id> --failed`。run が終わってから)。本文の編集は新しい run を起こして判定を付け直すが、PR 作成時の run の赤い `ci-gate` は残って必須チェックを赤のままにする (`.github/workflows/ci.yml` の `ci-gate` の上のコメント)

### 参照の面には使わない

参照の面 (`make example-shots`) は、Gyazo が同じ中身の絵に同じ URL を返すことを借り、URL が変わったかを
絵が変わったかの判定にしている (理由: [ADR-0027](../../../docs/decisions/0027-readable-surfaces.md) 決定 2)。
GitHub の添付は同じ絵でも毎回別の URL を返すので、この判定が成り立たない。参照の面は本線が戻るまで待つ。

### 通らない道

どれも「バイト列をページへ運ぶ」ところで止まる (いずれも 2026-09-22 実測 —
[#1320](https://github.com/mokume-metal/mokume/issues/1320) / [#1332](https://github.com/mokume-metal/mokume/issues/1332))。

| 試したこと | なぜ通らないか |
| --- | --- |
| `osascript` でクリップボードへ載せて `cmd+v` を合成する | 合成したキー入力はページへ届くだけで、**ブラウザの貼り付けコマンドを起こさない**。OS のクリップボードは読まれず、欄は空のまま |
| ページ内で `navigator.clipboard.read()` を呼ぶ | 読み取り権限が要り、自動操作には降りない (`NotAllowedError: Read permission denied`) |
| base64 を JavaScript のソースへ書き写して `File` を組む | 大きな文字列が道具の引数の途中で欠ける (14010 B のはずが 11571 B で上がった) |
| ページ内から `fetch` で手元のバイト列を取る | GitHub の CSP (`connect-src`) が外す |

クリップボードを手順から外したのは好みではなく、1 行目の理由で構造的に通らないからである。

## 大きさの上限

`github.com/user-attachments/…` は GitHub 自身の面なので camo を通らず、素の `<img src>` のまま出る
([#1306](https://github.com/mokume-metal/mokume/issues/1306))。本線の 4MB の目安も途中切断も無い。効くのは
GitHub の受け入れ上限で、**画像と GIF が 10MB・動画が 10MB (有料プランのリポジトリは 100MB)・その他が 25MB**。

## 検算

**投稿した後に、GET でリダイレクトを追い、原本とバイト数を突き合わせる。**

```bash
curl -sL "$ATTACHMENT_URL" -o /tmp/pulled -w '%{http_code} %{size_download}\n'
wc -c "<上げた原本>"                                                     # 一致すること
shasum -a 256 /tmp/pulled "<上げた原本>"                                 # 突き合わせを強めるなら
```

200 だけでは途中で切られていないことが見えない ([#369](https://github.com/mokume-metal/mokume/issues/369) が
camo で踏んだ形)。バイト数の一致は、貼ったものが原本であることまで言う。

本線と打ち方が違うのは、添付の URL が署名付き S3 への 302 で、**presigned URL が GET 用に署名されているため
HEAD は 403 で弾かれる**からである ([#1310](https://github.com/mokume-metal/mokume/issues/1310))。

| 打ち方 | 返るもの (2026-09-22 実測・[#1293](https://github.com/mokume-metal/mokume/pull/1293) に貼った添付) |
| --- | --- |
| `curl -sI` (HEAD・追わず) | **302** — `github-production-user-asset-….s3.amazonaws.com` への署名付き転送 |
| `curl -sIL` (HEAD・追う) | **403** — presigned URL が GET 用に署名されているため HEAD が弾かれる |
| `curl -s` (GET・追わず) | 302 |
| `curl -sL` (GET・追う) | **200** / 7182 bytes / `image/png` — 手元の原本とバイト数一致 |

## うまくいかないとき

| 症状 | 対処 |
| --- | --- |
| 投稿したのに 404 | まず数十秒おいて引き直す (公開は遅れて効く)。それでも 404 なら、その URL を含むコメントをまだ投稿していない — PR 本文へ書いただけでは公開されない (「投稿して公開する」)。未投稿を名乗るのは 404 だけである |
| 検算が 302 / 403 | 公開されていて、打ち方が合っていないだけ。`-sL` で GET で追い直す (「検算」)。**これを未公開と読んで Draft に落とさない** — 上げ先が 2 本とも塞がったように見え、描画 PR が 1 本も出せなくなる ([#1310](https://github.com/mokume-metal/mokume/issues/1310)) |
| 貼っても入力欄が空のまま (エラーも無い) | クリップボード経由で運ぼうとしている。`input[type=file]` へ渡す形に置き換える (「通らない道」) |
| 注入した入力欄が `find` で見つからない | `aria-label` を付けていない。画面外や `display:none` にも置かない |
| 動きが 1 枚の静止画になる / 形式が受け付けられない | この経路は原本とバイト単位で一致するので、渡したファイルを疑う (`shasum -a 256` で突き合わせる) |
| ブラウザが繋がらない | この経路は通らない。Gyazo も落ちているなら、PR にそう書いて Draft に落とし、有人のセッションへ返す |
| 写り込みに後から気付いた | **消す口が無い。** 本文から URL を外しても添付は残り、URL を知っていれば引ける。だから送る前に確かめるのが唯一の防壁である (SKILL.md の「守ること」)。出してしまったら、リポジトリの外に出た秘密として人に報告する |
| mp4 を貼りたい | 通る (`accept` に載り、83202 B のものが SHA-256 一致で上がった — [#1332](https://github.com/mokume-metal/mokume/issues/1332))。ただし動きの既定は WebP のまま |
