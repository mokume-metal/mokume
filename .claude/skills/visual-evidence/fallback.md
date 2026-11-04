<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# フォールバック — Gyazo が落ちているときに GitHub へ直接アップロードする

**通常の経路 (Gyazo) が落ちていると分かったときにだけ読む。** 判定は [SKILL.md](SKILL.md) の
「落ちているかを見分ける」が持ち、200 が返らなければ指示を待たずにここへフォールバックする。アップロード先が 1 つだけだと、
そこが落ちた瞬間に描画の PR を出せなくなるためである
([#1294](https://github.com/mokume-metal/mokume/issues/1294) で 178 本が一斉に 404 になった)。

撮り方・エンコードの方法・`desc` の組み立て方・貼り方は通常の経路と同じで、アニメーションも同じ WebP をそのまま出せる。
ここが持つのは、アップロードの方法と、アップロードした後の確かめ方の違いだけである。

## 前提

**秘密は 1 つも要らない代わりに、有人のセッションを要求する。**

- ブラウザを操作できる有人のセッションで、GitHub にサインイン済みであること
- ページの `input[type=file]` へファイルを渡せるブラウザのツール (file upload)
- エンコードのツールは通常の経路と同じ (SKILL.md の「前提」)

**無人セッション (`MOKUME_UNATTENDED=1`) では使えない。** Gyazo も落ちていて証跡を残せないときは、
そのことを PR 本文に書いて Draft にし、有人のセッションへ返す — 絵の無い描画 PR は
`drawing-evidence` が失敗として差し戻すので、何も言わずに進めても merge できない。隔離 worktree のサブエージェントは
ここも実行せず、材料を親へ返す (SKILL.md の「アップロードする」節の冒頭)。

## アップロードする

GitHub には添付の API が (REST にも GraphQL にも) 無い。通る形は 1 つだけで、**ページの
`input[type=file]` へファイルを渡す** (クリップボードは経由しない — 下の「通らない方法」)。

その入力欄があるかはページで違う (2026-09-22 実測・[#1332](https://github.com/mokume-metal/mokume/issues/1332)):

| ページ | `input[type=file]` |
| --- | --- |
| **PR** のコメント欄 | **ある** — `id="fc-new_comment_field"`。`accept` は `.gif,.jpeg,.jpg,.mov,.mp4,.png,.svg,.webm,.webp,…` |
| **Issue** のコメント欄 (React の新 UI) | **無い** — 「Paste, drop, or click to add files」は `<button>` で、欄は押すまで DOM に現れない |

だから手順は「無ければ自分で置く」形にし、どちらの UI でも分岐なしで通す:

**1. 入力欄を用意する。** PR なら `fc-new_comment_field` をそのまま使う。無いページでは注入する:

```javascript
const staging = document.createElement('input');
staging.type = 'file';
staging.id = 'mokume-evidence-input';
staging.setAttribute('aria-label', 'mokume evidence staging file input');  // find が拾えるように
staging.style.cssText = 'position:fixed;top:0;left:0;z-index:99999;background:#fff';
document.body.appendChild(staging);
```

**2. その欄へファイルを渡す** (ブラウザのツールの file upload。要素の参照は `find` で取る)。手元のバイト列を
ページへ運べるのはこの 1 手だけである。

**3. 注入した欄を使ったときは、コメント欄へ `paste` イベントを合成して渡し直す** (`fc-new_comment_field` へ渡した
ときは GitHub 自身のハンドラが受けるので要らない):

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

アップロードしたものは原本とバイト単位で一致する (PNG 2 本・WebP・mp4 で SHA-256 まで一致し、WebP はコメントの中でも
動いた — [#1332](https://github.com/mokume-metal/mokume/issues/1332))。

### 投稿して公開する

**URL は投稿して初めて有効になる。** 貼った時点ではアップロードした本人のセッションからしか読めず、無認証では 404 である。
公開されるのは、その URL が新しく投稿されたコメントに現れたときで、**少し遅れて反映される** (投稿直後の 404 は
「まだ」であって失敗ではない。数十秒おいて再取得する — [#1332](https://github.com/mokume-metal/mokume/issues/1332))。

```bash
bash scripts/comment.sh {issue,pr} <番号> --body-file <ファイル>
```

アップロードした欄と投稿先は別でよい。添付はスレッドに縛られないので、PR のコメント欄でアップロードしたものを Issue へ投稿しても
公開される。

**PR 本文へ載せたいときも、先にコメントで投稿する。** 本文に書いても (`scripts/edit-body.sh` でも、その中で使う `gh pr edit` でも)、本文の編集は
新しい投稿に数えられず 404 のままである ([#1306](https://github.com/mokume-metal/mokume/issues/1306))。
`drawing-evidence` が読むのは PR 本文なので、描画 PR ではこの順を守る:

1. コメント欄へ貼って URL を得る
2. **その URL を含むコメントを投稿する** (`scripts/comment.sh`) — ここで公開される
3. 同じ URL を PR 本文へ書く (`gh pr create --body-file`。既存の本文を直すなら `scripts/edit-body.sh pr <番号>` の `--fetch` → `--body-file`。発言ではないので署名は付かない)
4. 本文を書き換えれば (ラッパーの中身も `gh pr edit`)、本文の編集が `pr-gate` の新しい run をトリガーし、`drawing-evidence` が再評価される (再実行は要らない — `.github/workflows/pr-gate.yml` の冒頭)

### リファレンスには使わない

リファレンス (`make example-shots`) の絵は通常の経路 (Gyazo) だけに上げ、通常の経路が落ちていれば戻るまで待つ
([ADR-0027](../../../docs/decisions/0027-readable-surfaces.md) 決定 2・[#3526](https://github.com/mokume-metal/mokume/issues/3526))。
上げ先を 2 つにすると、ドキュメントコメントの URL が 2 つの置き場に散り、URL を読み書きする正規表現
(`scripts/example-shots.py` の `IMAGE_LINE`) が 2 系統になり、死活のチェック (`scripts/check-external-assets.py`) が引く絵も 2 つの置き場にまたがる。
GitHub の添付は API で消せないので、絵を差し替えるたびに孤児も残る。

### 通らない方法

どれも「バイト列をページへ運ぶ」ところで止まる (いずれも 2026-09-22 実測 —
[#1320](https://github.com/mokume-metal/mokume/issues/1320) / [#1332](https://github.com/mokume-metal/mokume/issues/1332))。

| 試したこと | なぜ通らないか |
| --- | --- |
| `osascript` でクリップボードへ入れて `cmd+v` を合成する | 合成したキー入力はページへ届くだけで、**ブラウザの貼り付けコマンドをトリガーしない**。OS のクリップボードは読まれず、欄は空のまま |
| ページ内で `navigator.clipboard.read()` を呼ぶ | 読み取り権限が要り、自動操作には付与されない (`NotAllowedError: Read permission denied`) |
| base64 を JavaScript のソースへ書き写して `File` を組み立てる | 大きな文字列がツールの引数の途中で欠ける (14010 B のはずが 11571 B でアップロードされた) |
| ページ内から `fetch` で手元のバイト列を取る | GitHub の CSP (`connect-src`) が拒否する |

クリップボードを手順から外したのは好みではなく、1 行目の理由で構造的に通らないからである。

## 大きさの上限

`github.com/user-attachments/…` は GitHub 自身のドメインなので camo を通らず、素の `<img src>` のまま出る
([#1306](https://github.com/mokume-metal/mokume/issues/1306))。通常の経路の 4MB の目安も途中切断も無い。効くのは
GitHub の受け入れ上限で、**画像と GIF が 10MB・動画が 10MB (有料プランのリポジトリは 100MB)・その他が 25MB**。

## 確認

**投稿した後に、GET でリダイレクトを追い、原本とバイト数を突き合わせる。**

```bash
curl -sL "$ATTACHMENT_URL" -o /tmp/pulled -w '%{http_code} %{size_download}\n'
wc -c "<アップロードした元ファイル>"                                                     # 一致すること
shasum -a 256 /tmp/pulled "<アップロードした元ファイル>"                                 # 突き合わせを強めるなら
```

200 だけでは途中で切られていないことが分からない ([#369](https://github.com/mokume-metal/mokume/issues/369) が
camo で踏んだ形)。バイト数の一致は、貼ったものが原本であることまで示す。

通常の経路とリクエストの方法が違うのは、添付の URL が署名付き S3 への 302 で、**presigned URL が GET 用に署名されているため
HEAD は 403 で拒否される**からである ([#1310](https://github.com/mokume-metal/mokume/issues/1310))。

| リクエストの方法 | 返るもの (2026-09-22 実測・[#1293](https://github.com/mokume-metal/mokume/pull/1293) に貼った添付) |
| --- | --- |
| `curl -sI` (HEAD・追わず) | **302** — `github-production-user-asset-….s3.amazonaws.com` への署名付きリダイレクト |
| `curl -sIL` (HEAD・追う) | **403** — presigned URL が GET 用に署名されているため HEAD が拒否される |
| `curl -s` (GET・追わず) | 302 |
| `curl -sL` (GET・追う) | **200** / 7182 bytes / `image/png` — 手元の原本とバイト数一致 |

## うまくいかないとき

| 症状 | 対処 |
| --- | --- |
| 投稿したのに 404 | まず数十秒おいて再取得する (公開は遅れて反映される)。それでも 404 なら、その URL を含むコメントをまだ投稿していない — PR 本文へ書いただけでは公開されない (「投稿して公開する」)。未投稿を示すのは 404 だけである |
| 確認で 302 / 403 が返る | 公開されていて、リクエストの方法が合っていないだけ。`-sL` で GET で追い直す (「確認」)。**これを未公開と読んで Draft にしない** — アップロード先が 2 つとも塞がったように見え、描画 PR が 1 本も出せなくなる ([#1310](https://github.com/mokume-metal/mokume/issues/1310)) |
| 貼っても入力欄が空のまま (エラーも無い) | クリップボード経由で運ぼうとしている。`input[type=file]` へ渡す形に置き換える (「通らない方法」) |
| 注入した入力欄が `find` で見つからない | `aria-label` を付けていない。画面外や `display:none` にも置かない |
| アニメーションが 1 枚の静止画になる / 形式が受け付けられない | この経路は原本とバイト単位で一致するので、渡したファイルを疑う (`shasum -a 256` で突き合わせる) |
| ブラウザが繋がらない | この経路は通らない。Gyazo も落ちているなら、PR にそう書いて Draft にし、有人のセッションへ返す |
| 写り込みに後から気付いた | **削除する手段が無い。** 本文から URL を外しても添付は残り、URL を知っていれば取得できる。だから送る前に確かめるのが唯一の防壁である (SKILL.md の「守ること」)。出してしまったら、リポジトリの外に出た秘密として人に報告する |
| mp4 を貼りたい | 通る (`accept` に含まれ、83202 B のものが SHA-256 一致でアップロードできた — [#1332](https://github.com/mokume-metal/mokume/issues/1332))。ただしアニメーションの既定は WebP のまま |
