#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""外に置いた資産 (絵・動き) が生きているかを見る (#483)。

**塞ぐのは「公開した後にリンクが切れる」である。** [ADR-0027](../docs/decisions/0027-readable-surfaces.md)
決定 2 により、実行結果の絵はリポジトリに入らず外部ホスティングに置かれ、説明文には
それを指す 1 行だけが残る。指し先はこちらの都合と無関係に消えうるので、**壊れる瞬間は
どの PR とも一致しない** — PR ごとの検査では原理的に捕まらず、定期で引くしかない。

**見るのは資産として参照している URL だけである。** 素のリンク (本文から他の文書へ
飛ぶもの) は見ない — 追跡下の Markdown が持つ外部リンクを全部引けば、相手側の一時的な
不調やレート制限で検査が揺れる。外部 URL を per-PR の検査から外した判断は
[#90](https://github.com/mokume-metal/mokume/issues/90) が既に下しており、ここはその
外側に「資産の死活だけを、定期で」を足す形になる。

**0 件なら赤にする。** 書式が変わって 1 本も拾えなくなった状態は、全部生きているのと
同じ緑で表れる。検査が空回りしていることを緑で隠さない (`check-published-reference.py` /
`check-docs-links.py` と同じ守り)。

**出所を必ず添える。** 切れた URL だけを見せられても、24 本ある指し先のどれを撮り直せば
よいか分からない。ファイルと行を出せば、そのまま `///` の該当行へ飛べる。

**探すのは説明文と Markdown の本文だけ。** ADR-0027 決定 2 が絵の URL の置き場をそこに
定めているので、それ以外に書かれた URL は資産ではない — 実際、検査の資材 (テストの中の
`https://example.invalid/…`) を資産として数えると、**壊れているべきものを死活の赤として
報告する**ことになる。Swift は `///` の行だけを見、Markdown はコード塊を潰してから見る
(書き方の例示を実物と数えないため。潰し方の正典は `check-docs-links.py` にあり、写さずに
借りている)。

**リリースノートの絵も引く** (#2268)。描画に触れた PR の本文の絵は「唯一の検証記録で、
merge の後には足せない」(AGENTS.md) が、説明文にも Markdown にも載らないので上の走査では
見えず、[#1294](https://github.com/mokume-metal/mokume/issues/1294) で 178 本が 404 に
なったときも、PR の絵が読めなくなったことを誰も引いていなかった。その絵は Release の
「この版の絵」に写される (ADR-0036 決定 7) ので、**直近 `RELEASES_WATCHED` 版のノートに
載った絵**を同じ検査で引く。読むのは Release の本文 (PR 本文を引き直さない — 読み手が見る
のはノートの絵で、PR の数ぶん API を打たずに済む)。節の形は書く側の `release.py` が持つので、
読む関数もそちらを借りる。

**PR ごとの検査には置かない。** 外部 URL を per-PR の検査から外した判断
([#90](https://github.com/mokume-metal/mokume/issues/90)) は動かさない — ここは日次の定期検査の
ままで、見る場所が 2 つ (説明文 / ノートの絵の節) になっただけである。0 本なら赤にする守りは
**説明文の側にだけ**掛ける: 描画に触れた PR の無い週はノートに絵の節が無く、それは正常だから。
その代わり、ノートの側は版数と本数を毎回出す (0 本のときも黙らない)。

**窓は直近 `RELEASES_WATCHED` 版だけ**で、窓の外に出た版 (日次のリリースなら約 1 週間後) の絵が
切れたことは拾えない。置き場ごと止まる事象は説明文の側でも拾えるので、ノートの側が受けもつ
のは個別の消失である。窓を広げると引く本数が版ぶん増え、置き場が応えないときの最悪の所要が
job の上限に近づく (1 版あたり 35〜53 本)。
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import pathlib
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

# タイムアウトと `<img>` の綴りは site_source が持つ (#815)
from site_source import FETCH_TIMEOUT_SECONDS, HTML_IMAGE  # noqa: E402

# リリースノートの「この版の絵」の節の形は、書く側の release.py が持つ (#2268)
import release  # noqa: E402

# 資産として参照している外部 URL の書き方は 2 つある。
#   - Markdown の画像 `![説明](https://…)` — `///` の中も普通の .md も同じ書式
#   - docc の `@Image(source: "https://…")` / `@Video(source: "https://…")`
# 素のリンク `[文字](https://…)` は拾わない (`!` の有無で分かれる)
MARKDOWN_IMAGE = re.compile(r"!\[[^\]]*\]\((https?://[^)\s]+)\)")
DOCC_SOURCE = re.compile(r"@(?:Image|Video)\s*\(\s*source:\s*\"(https?://[^\"]+)\"")
# HTML の絵 `<img src="https://…">`。入口のページ (#482) が絵を外に置くので、
# **いちばん人目に付く絵だけが死活の外**にならないようここも見る。
# 綴りは site_source が持つ (#815) — 入口を検める側 (check-entry.py) と同じものを読む

# Swift の説明文。ADR-0027 決定 2 により、絵を指す行はここに置かれる
DOC_COMMENT = re.compile(r"^\s*///")

# 引くリリースノートの版数 (#2268)。日次のリリースなので約 1 週間ぶん。絵のある版は 1 版
# あたり 35〜53 本 (2026-10-10 の実測。説明文の側は 321 本) で、窓が全部絵のある版で埋まると
# 説明文のほぼ倍になる。広げるほど、置き場が応えないときの最悪の所要
# (本数 × FETCH_TIMEOUT_SECONDS、引き直しで倍) が job の上限に近づく
RELEASES_WATCHED = 7

# リリースノート由来の指し先の出所の頭。dead_report が、直し方の違う出所を見分けるのに使う
RELEASE_ORIGIN_PREFIX = "Release "

# 相手が bot を弾かないように名乗る。無名の要求を落とす配信は珍しくない
USER_AGENT = "mokume-external-assets-check (+https://github.com/mokume-metal/mokume)"


def _mask_code():
    """Markdown のコード塊を潰す関数を `check-docs-links.py` から借りる。

    **写さない。** フェンスとインラインコードの潰し方には対の取り方の細部があり、
    2 か所に置くと片方だけが直る。名前にハイフンを含むので import は経路から行う。
    """
    path = pathlib.Path(__file__).resolve().parent / "check-docs-links.py"
    spec = importlib.util.spec_from_file_location("check_docs_links", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.mask_code


mask_code = _mask_code()


class Reference:
    """1 本の指し先と、その出所。"""

    def __init__(self, url: str, path: str, line: int, label: str | None = None) -> None:
        self.url = url
        self.path = path
        self.line = line
        # ファイルの行で名乗れない出所 (Release のノート) は、名乗りをそのまま持つ
        self.label = label

    @property
    def origin(self) -> str:
        return self.label or f"{self.path}:{self.line}"


def tracked_files(root: pathlib.Path) -> list[str]:
    """追跡下の、説明文を持ちうるファイル。

    **名指しするのは形式だけで、置き場は名指ししない** — `Sources/` の下に限る等の
    絞りを書くと、次に説明文の置き場が増えたときに同じ穴が空く。読めない形式や
    説明文を持たない形式は、下の `readable` が素通りさせる。
    """
    completed = subprocess.run(
        ["git", "ls-files", "*.swift", "*.md", "*.html"],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    )
    return [line for line in completed.stdout.splitlines() if line]


def readable(name: str, text: str) -> str:
    """指し先を探してよい部分だけを残す (行数と行番号はそのまま保つ)。"""
    if name.endswith(".swift"):
        return "\n".join(line if DOC_COMMENT.match(line) else "" for line in text.split("\n"))
    if name.endswith(".html"):
        # HTML にはコード塊の書式が無いので、そのまま見る
        return text
    return mask_code(text)


def references_in(text: str, path: str) -> list[Reference]:
    """指し先と、その出所の行。

    **1 行ずつではなく本文全体を見る。** HTML は属性を改行で分けて書けるので
    (`<img` の次の行に `src="…"`)、行で切ると 2 つが別の行に落ちて 1 本も拾えない。
    しかも拾えなかったことは緑で表れる。行番号は一致した位置から数える
    (`readable` は行数を保つので、潰した後でも元の行と一致する)。
    """
    readable_text = readable(path, text)
    found = []
    for pattern in (MARKDOWN_IMAGE, DOCC_SOURCE, HTML_IMAGE):
        for match in pattern.finditer(readable_text):
            found.append(
                Reference(match.group(1), path, readable_text.count("\n", 0, match.start()) + 1)
            )
    return sorted(found, key=lambda reference: reference.line)


def collect(root: pathlib.Path) -> list[Reference]:
    found = []
    for name in tracked_files(root):
        path = root / name
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            # 読めないもの (削除済み・想定外の符号化) に指し先は書けない
            continue
        found.extend(references_in(text, name))
    return found


class ReleaseReadError(Exception):
    """Release のノートを読めなかった。検査が成立していないので、呼び手は赤にする。"""


def fetch_releases(count: int, root: pathlib.Path) -> list[tuple[str, str]]:
    """直近 `count` 版の (タグ, ノートの本文)。新しい順。下書きは数えない。

    **読めなかったことを空の一覧にしない。** 空は「絵の無い週」と同じ緑で表れる。
    リポジトリは `root` の origin から gh が引く (`{owner}/{repo}`)。
    """
    try:
        completed = subprocess.run(
            ["gh", "api", f"repos/{{owner}}/{{repo}}/releases?per_page={count}"],
            cwd=root,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise ReleaseReadError(f"gh を起こせない: {error}") from error
    if completed.returncode != 0:
        raise ReleaseReadError(completed.stderr.strip() or f"gh api が {completed.returncode} で終わった")
    try:
        releases = json.loads(completed.stdout)
        return [
            (item["tag_name"], item.get("body") or "")
            for item in releases
            if not item.get("draft")
        ]
    except (ValueError, KeyError, TypeError) as error:
        raise ReleaseReadError(f"gh api の応答を読めない: {error}") from error


def release_references(releases: list[tuple[str, str]]) -> list[Reference]:
    """各版のノートの「この版の絵」にある指し先。出所は `Release <タグ> (#PR)`。

    節の読み方は release.py の `picture_references` が持つ (書く側と同じ記法を読む)。
    PR の番号は、直す側が PR 本文とノートの両方を辿れるように名乗る。
    """
    found = []
    for tag, body in releases:
        for picture in release.picture_references(body):
            where = f"{RELEASE_ORIGIN_PREFIX}{tag}" + (f" (#{picture.pull})" if picture.pull else "")
            found.append(Reference(picture.url, f"{RELEASE_ORIGIN_PREFIX}{tag}", picture.line, where))
    return found


# 引き直してよい失敗 (#1676)。**赤は「指し先が消えた」を意味する** — その赤を受けて
# `report-dead-assets.sh` が撮り直しを求める起票をするので、配信が一時的に断っただけの
# 失敗を消失と同じ赤に数えてはならない。実際、生きている 178 本のうち 3 本が続けて引いた
# ときだけ 503 を返し、個別に引き直すと 200 だった。
#
# 4xx は引き直しても答えが変わらないので引き直さない。4xx が消失を意味するとは限らない
# ([#1294](https://github.com/mokume-metal/mokume/issues/1294) の 404 は、置き場が配信を
# 止めていただけだった) が、そうした停止は日の単位で続き、数十秒後に引き直しても救えない
# — そちらは `dead_report` の「全滅」の断りが受ける。例外は 408 と 429 で、これは相手自身が
# 「待てば通りうる」と言っている。5xx と、応答までたどり着かなかった失敗 (名前解決・接続・
# 待ち切れ) は一時的でありうる
RETRYABLE_CLIENT_ERRORS = frozenset({408, 429})

# 引き直す前に 1 度だけ待つ秒数。**待つのは全体で 1 回で、1 本ごとではない** —
# 置き場が丸ごと 5xx を返しているときに 1 本ずつ待つと、待ちが本数ぶん積み上がる。
# 相手が `Retry-After` で待ちを指定していればそれに従うが、上限で切る (日次の検査が
# 相手の指定ひとつで何時間も止まらないように)。ここで諦めたものは「応えない」と名乗る
RETRY_WAIT_SECONDS = 10
RETRY_WAIT_LIMIT_SECONDS = 60


class Failure:
    """引けなかった理由と、引き直す価値があるか。"""

    def __init__(self, reason: str, transient: bool, retry_after: float | None = None) -> None:
        self.reason = reason
        self.transient = transient
        self.retry_after = retry_after


def _retry_after(error: urllib.error.HTTPError) -> float | None:
    """`Retry-After` の秒数。日付の形や読めない値は無いものとする (既定の待ちに任せる)。"""
    value = (error.headers or {}).get("Retry-After")
    try:
        return max(0.0, float(value)) if value is not None else None
    except ValueError:
        return None


def _unreachable_is_transient(error: Exception) -> bool:
    """応答までたどり着かなかった失敗が、引き直す価値のあるものか。

    名前解決・接続・待ち切れは OSError として来る (URLError は理由を `reason` に包む)。
    **証明書の検証失敗は OSError の仲間だが恒久的**なので外す。URL の書き方の誤り
    (`unknown url type` や符号化できない文字) は OSError でないので、ここで外れる。
    外すのは待ち時間のためで、どちらにしても最後は赤になる。
    """
    reason = error.reason if isinstance(error, urllib.error.URLError) else error
    if isinstance(reason, ssl.SSLCertVerificationError):
        return False
    return isinstance(reason, OSError)


def probe(url: str) -> Failure | None:
    """引けたら None、引けなければその理由。

    **HEAD ではなく GET で引く。** HEAD に 405 を返す配信があり、その 405 を死活の
    判定に混ぜると生きている資産まで赤くなる。本文は読み捨てる。
    """
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT_SECONDS) as response:
            response.read(1)
        return None
    except urllib.error.HTTPError as error:
        # 例外そのものが応答なので閉じる (site_source.py の Source.read と同じ理由)
        error.close()
        transient = error.code >= 500 or error.code in RETRYABLE_CLIENT_ERRORS
        return Failure(f"HTTP {error.code}", transient, _retry_after(error))
    except Exception as error:  # 名前解決・接続・証明書の失敗をそのまま名乗る
        return Failure(str(error), _unreachable_is_transient(error))


def probe_all(urls: list[str], sleep=time.sleep) -> dict[str, Failure]:
    """引けなかった指し先と、その理由。

    一時的でありうる失敗は、全体を引き終えてから 1 度だけ待って引き直す。引き直しても
    引けなかったものだけを返す — **引き直しは 1 回きり**で、続けて断られるなら
    検査の側で粘ることはしない。返したものの `transient` が立っていれば、それは
    「消えた」ではなく「応えない」である (`dead_report` が名乗り分ける)。
    """
    failures = {}
    for url in urls:
        failure = probe(url)
        if failure is not None:
            failures[url] = failure

    retry = [url for url, failure in failures.items() if failure.transient]
    if retry:
        asked = [failures[url].retry_after or 0 for url in retry]
        sleep(min(max([RETRY_WAIT_SECONDS, *asked]), RETRY_WAIT_LIMIT_SECONDS))
        for url in retry:
            again = probe(url)
            if again is None:
                del failures[url]
            else:
                failures[url] = again

    return failures


def host_of(url: str) -> str:
    """指し先のホスト。取れなければ URL をそのまま名乗る (黙って束ねない)。"""
    return urllib.parse.urlsplit(url).hostname or url


def dead_report(
    origins: dict[str, list[str]],
    dead: list[tuple[str, str, list[str]]],
    unanswered: frozenset[str] = frozenset(),
) -> list[str]:
    """引けなかったときに出す行 (#1333)。

    **ホストごとの内訳を、1 本ずつの一覧より先に置く。** 日次の起票
    (`report-dead-assets.sh` → `report-check-failure.sh`) は検査の出力を**先頭 200 行で
    切る**ので、一覧の後ろに置いた要約は Issue の本文に載らない。起票の「対処」が最初に
    問うのは「1 本か、全部か」— 個別の消失と、置き場の側で起きた事象では手が違う — なので、
    その材料を切られない位置に置く。

    [#1294](https://github.com/mokume-metal/mokume/issues/1294) は材料が本文に無いまま
    「アカウント側で起きた事象に見える」と診断し、実際には置き場のサービス全体が止まって
    いた。同じ切り分けを [#1331](https://github.com/mokume-metal/mokume/issues/1331) で
    もう一度やり直している。

    **引き直しても応えなかったもの (`unanswered`) は、消えたとは名乗らない** (#1676)。
    5xx や接続の失敗は置き場が応えていないことを言っているだけで、撮り直しを求めると
    生きている絵を撮り直させることになる。

    **ホストが生きているかを引きに行くことはしない。** 根が 404 を返す配信は健全なときにも
    あるので、判定に混ぜると揺れる。**本数の内訳だけで「1 本か、全部か」には答えられる。**
    """
    total: dict[str, int] = {}
    for url in origins:
        total[host_of(url)] = total.get(host_of(url), 0) + 1

    failed: dict[str, int] = {}
    for url, _reason, _where in dead:
        failed[host_of(url)] = failed.get(host_of(url), 0) + 1

    lines = ["外に置いた資産が引けない (ホストごとの内訳):"]
    wiped = False
    for host in sorted(failed):
        # 指し先が 1 本しかないホストは「全滅」と名乗らない。それは個別の消失であって、
        # 置き場の側で起きた事象ではない (名乗ると、手の違う 2 つが同じ顔になる)
        whole = failed[host] == total[host] and total[host] > 1
        wiped = wiped or whole
        lines.append(
            f"  {host}: 指し先 {total[host]} 本のうち {failed[host]} 本"
            + (" — 全滅" if whole else "")
        )

    if wiped:
        lines += [
            "",
            "全滅しているホストがある。**撮り直す前に、置き場そのものの死活と告知を確かめる** —",
            "配信が止まっているだけなら絵は消えておらず、撮り直しても上げ先が無い",
            "(#1331 が実例: 置き場が不正アクセスを受けて配信を止めていた)。",
        ]

    if unanswered:
        lines += [
            "",
            f"{len(unanswered)} 本は、待って引き直しても応えなかった (5xx・接続の失敗)。",
            "これは指し先が消えたのではなく、置き場が応えていないことを言っている。",
            "**撮り直す前に、時間を置いて検査をもう一度流す** — 通れば撮り直しは要らない。",
        ]

    lines += ["", "引けなかった指し先と出所:"]
    for url, reason, where in dead:
        mark = " (引き直しても応えない)" if url in unanswered else ""
        lines.append(f"  {url} — {reason}{mark}")
        lines += [f"    {origin}" for origin in where]

    lines += [
        "",
        "撮り直しの手順は .claude/skills/visual-evidence/ が持つ。"
        "撮り直したら、指している行の URL を差し替える (ADR-0027 決定 2)。",
    ]
    # 出所が Release のノートの絵は、同じ URL が PR 本文にも残っている。片方だけ直すと、
    # 直した側だけが読めて、もう片方 (PR の記録か版の記録) が切れたまま残る
    if any(where.startswith(RELEASE_ORIGIN_PREFIX) for _url, _reason, wheres in dead for where in wheres):
        lines += [
            f"出所が `{RELEASE_ORIGIN_PREFIX}<タグ> (#PR)` の絵は、リリースノートに写された URL である。"
            "PR 本文 (`gh pr edit`) とそのリリースのノート (`gh release edit <タグ> --notes-file`) の"
            "両方で差し替える。",
        ]
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1],
        help="走査するリポジトリ (既定: このスクリプトのリポジトリ)",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="引かずに、見つけた指し先とその出所を並べる",
    )
    parser.add_argument(
        "--releases",
        type=int,
        default=RELEASES_WATCHED,
        metavar="N",
        help=f"絵を引くリリースノートの直近の版数 (既定: {RELEASES_WATCHED}。0 で見ない)",
    )
    arguments = parser.parse_args()

    references = collect(arguments.root)
    if not references:
        print(
            "外部資産の指し先を 1 つも見つけられない — 検査が成立していない。\n"
            "説明文の絵の書き方が変わったなら、この道具の拾い方も直す",
            file=sys.stderr,
        )
        return 1

    print(f"外部資産の指し先: {len({r.url for r in references})} 本 ({len(references)} 箇所から)")

    # ノートの側は 0 本でも赤にしない (描画に触れた PR の無い週は正常) が、読めなかったことは
    # 赤にする。空の一覧は「絵の無い週」と同じ緑で表れてしまう
    if arguments.releases > 0:
        try:
            releases = fetch_releases(arguments.releases, arguments.root)
        except ReleaseReadError as error:
            print(f"リリースノートを読めない — 検査が成立していない: {error}", file=sys.stderr)
            return 1
        pictured = release_references(releases)
        print(
            f"リリースノートの絵: 直近 {len(releases)} 版のうち "
            f"{len({r.path for r in pictured})} 版に {len({r.url for r in pictured})} 本"
        )
        references += pictured

    # 同じ絵は複数の場所から指されうる。引くのは 1 回でよいが、赤くなったときは
    # 出所を全部見せる (撮り直しは指している側の全部に効く)
    origins: dict[str, list[str]] = {}
    for reference in references:
        origins.setdefault(reference.url, []).append(reference.origin)

    if arguments.list:
        for url, where in sorted(origins.items()):
            print(f"  {url}\n    {' / '.join(where)}")
        return 0

    failures = probe_all(sorted(origins))
    dead = [(url, failures[url].reason, origins[url]) for url in sorted(failures)]
    unanswered = frozenset(url for url, failure in failures.items() if failure.transient)

    if dead:
        for line in dead_report(origins, dead, unanswered):
            print(line, file=sys.stderr)
        return 1

    print(f"ok: {len(origins)} 本すべて引けた")
    return 0


if __name__ == "__main__":
    sys.exit(main())
