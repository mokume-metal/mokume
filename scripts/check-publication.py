#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""公開が追随していることを、公開先を引いて確かめる (#483)。

**塞ぐのは「ビルドは緑のまま、公開だけが古い」である。** `.github/workflows/pages.yml`
は deploy の直後に公開先を引いて中身を確かめるが、それが見ているのは**その回の公開**
だけである。何かの理由で公開が一度も起きなかった期間は、誰も引かない — Actions は緑、
PR も緑、気付く手掛かりは人が面を読んだときにしか無い ([ADR-0027](../docs/decisions/0027-readable-surfaces.md)
決定 3 の「ビルドの緑は公開の緑ではない」)。

**だから公開の側に印を置き、外から引いて手元の `main` と突き合わせる。** 公開の
ワークフローが `publish-stamp.txt` に組んだコミットの SHA を 1 行だけ書き、この道具が
それを引く。印は説明文の 1 文字の直しまで拾う — 面の見た目が変わらない直しでも SHA は
動くからである。

**GitHub の Deployments の記録では足りない。** あれは「GitHub が deploy を受け付けた」
という記録で、配信が実際にその中身を返しているかは別の事実である。完了条件が「引いて
確かめる」と書いているのはそこで、記録を読むだけの経路は配信側の事故を素通りさせる。

**印は JSON にしない。** 中身は SHA 1 つで、増える予定も無い。プロセスの外とやりとりする
JSON には `Schemas/` の正典が要る ([ADR-0018](../docs/decisions/0018-observation-and-control-surface.md))
が、そこまでの形を先回りで作らない ([ADR-0001](../docs/decisions/0001-founding-principles.md)
原則 4)。書く側の口 (`--write-stamp`) をこの道具自身に持たせてあるので、**形式の正典は
読む側と書く側で 1 本**である。

**中身の照合はこの道具の仕事ではない。** 公開された面が手元のカタログと合っているかは
`scripts/check-published-reference.py` が既に URL を受け取れる形で持っている。役割が違う
2 つを 1 本に混ぜず、ワークフローが両方を呼ぶ (ADR-0008 決定 5 の「既存の機構の責務を
広げる」段)。

## 独自ドメイン

向け先は apex `mokume.org`。面は root に置かれ、その上へ手で書く層 (`Documentation/site/`)
が丸ごと被さる (ADR-0027 決定 3)。**リポジトリ側が意図の正典**で、GitHub 側の設定は
その写しである ([ADR-0006](../docs/decisions/0006-github-settings-as-code.md) と同じ向き)。
`CNAME` ファイルは置かない — Actions から公開する構成では GitHub がそれを無視すると
明記されているので、置けば「効いていない正典」が 1 つ増えるだけになる。

引く先が `https://` なので、**引けること自体が証明書の検査**を兼ねる (urllib は既定で
証明書を検証する)。

設定はメンテナが 1 度だけ行う (Administration が要るのでエージェントの token では通らない。
ADR-0003 決定 1)。未設定の間この検査は赤いが、それは故障ではなく催促である — 出力が
そのまま手順になる。
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

# 読み口・相手を待つ上限・引けなかったときの向きは site_source が持つ (#815 / #865)。
# この検査と面の 3 本は同じ公開先を見るので、値や向きが食い違うと「手元では通るが
# 公開先だけ落ちる」が起きる
from site_source import FETCH_TIMEOUT_SECONDS, Source, Unreachable  # noqa: E402,F401

# 面を向ける先。ここが意図の正典で、GitHub 側の設定はその写し
DOMAIN = "mokume.org"
# 公開の印の名前。root に置く — 読む面ではなく機械が引く 1 本である (ADR-0027 決定 3)
STAMP_NAME = "publish-stamp.txt"
# 公開が走っている最中を赤にしないための猶予。main への push から公開が終わるまでの
# 時間 (swift build を含むので数分〜十数分) に、ランナーの混雑ぶんの余裕を足した幅
GRACE_SECONDS = 45 * 60

COMMIT = re.compile(r"^[0-9a-f]{40}$")

# 設定が入っていないときに出す手順。**検査の出力がそのまま手順になる**形にしておく —
# 赤を見た人が、別の文書を探さずに片付けられる
SETUP = f"""\
メンテナが 1 度だけ行う設定 (どちらもエージェントの token では通らない):

  1. DNS (Cloudflare) — apex {DOMAIN} の A / AAAA を GitHub Pages の宛先へ向ける。
     **proxy は切る (DNS only)。** proxy 下では証明書の発行が通らない。
     宛先の正典は GitHub のドキュメント:
     https://docs.github.com/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site
  2. GitHub — リポジトリの Settings > Pages で custom domain に {DOMAIN} を入れ、
     検証が通った後に Enforce HTTPS を入れる (証明書の発行に最大 24 時間かかる)
"""


def stamp_path(directory: pathlib.Path) -> pathlib.Path:
    return directory / STAMP_NAME


def write_stamp(directory: pathlib.Path, commit: str) -> pathlib.Path:
    """公開物に印を置く。公開のワークフローが呼ぶ口。"""
    if not COMMIT.match(commit):
        raise SystemExit(f"印に書くコミットが 40 桁の SHA ではない: {commit!r}")
    directory.mkdir(parents=True, exist_ok=True)
    path = stamp_path(directory)
    path.write_text(f"{commit}\n", encoding="utf-8")
    return path


def read_stamp(site: str) -> tuple[str | None, str | None]:
    """公開先の印を読む。返すのは (SHA, 読めなかった理由) で、どちらか一方だけが入る。

    **引く先はディレクトリでもよい。** 手元で組んだ `_site` にそのまま当てられると、
    配信の事故と組み立ての事故を切り分けられる (`check-published-reference.py` が
    同じ形をとっているのに倣う) — その分岐は `Source` が持つ。

    **引けなかったときの向きも `Source` が持つ** (#865)。ここで受け直して文字列にするのは、
    この口だけが「(SHA, 理由)」を返す契約だからである — 呼び出し側が猶予 (`GRACE_SECONDS`)
    の判定と並べて名乗る。**「無い」と「引けなかった」は Source の側で既に分かれている**
    ので、ここでは 404 とディレクトリの取り違えが起きない。
    """
    try:
        raw = Source(site).read(STAMP_NAME)
    except Unreachable as unreachable:
        return None, str(unreachable)
    if raw is None:
        return None, f"{site} に印 ({STAMP_NAME}) が無い"

    text = raw.decode("utf-8", errors="replace").strip()
    if not COMMIT.match(text):
        return None, f"印の中身が 40 桁の SHA ではない: {text[:80]!r}"
    return text, None


def pages_settings(repo: str) -> dict | None:
    """GitHub 側の Pages の設定。Pages が無効なら None。"""
    completed = subprocess.run(
        ["gh", "api", f"repos/{repo}/pages"],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        if "404" in completed.stderr or "Not Found" in completed.stderr:
            return None
        raise SystemExit(f"Pages の設定を読めない:\n{completed.stderr.strip()}")
    return json.loads(completed.stdout)


def domain_problems(settings: dict | None, domain: str = DOMAIN) -> list[str]:
    """GitHub 側の設定が、リポジトリ側の意図どおりかを見る。"""
    if settings is None:
        return ["Pages が有効になっていない"]
    problems = []
    cname = settings.get("cname")
    if cname != domain:
        problems.append(f"custom domain が {cname!r} で、{domain!r} ではない")
    if not settings.get("https_enforced"):
        problems.append("Enforce HTTPS が入っていない")
    return problems


def commits_behind(published: str, head: str) -> list[tuple[str, int]] | None:
    """`published..head` のコミットを新しい順に (SHA, 時刻)。印が履歴に無ければ None。"""
    completed = subprocess.run(
        ["git", "log", "--format=%H %ct", f"{published}..{head}"],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        return None
    behind = []
    for line in completed.stdout.splitlines():
        sha, _, seconds = line.partition(" ")
        behind.append((sha, int(seconds)))
    return behind


def freshness_problems(
    published: str,
    head: str,
    behind: list[tuple[str, int]] | None,
    now: int,
    grace: int = GRACE_SECONDS,
) -> list[str]:
    """公開が追随しているか。**判定はここだけ**にして、引く側と分けてある。"""
    if published == head:
        return []
    if behind is None:
        return [
            f"公開されているコミット {published[:12]} が手元の履歴に無い — "
            "ずっと古い公開が居座っているか、履歴の取り方が浅い"
        ]
    if not behind:
        # 公開のほうが新しい (手元のチェックアウトが古い)。追随の問題ではない
        return []

    stale = [(sha, seconds) for sha, seconds in behind if now - seconds > grace]
    if not stale:
        return []

    oldest_sha, oldest_seconds = stale[-1]
    minutes = (now - oldest_seconds) // 60
    return [
        f"公開が {len(behind)} コミットぶん古い (公開: {published[:12]} / main: {head[:12]})。"
        f"いちばん古い未公開のコミットは {oldest_sha[:12]} で、{minutes} 分前に入っている"
    ]


def head_commit() -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True
    )
    return completed.stdout.strip()


def build_parser() -> argparse.ArgumentParser:
    """口の定義。**既定を検められるように切り出してある** (#818)。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--write-stamp",
        type=pathlib.Path,
        metavar="DIR",
        help="公開物に印を置く (公開のワークフローが呼ぶ口)。--commit と対で使う",
    )
    parser.add_argument("--commit", help="印に書くコミット (既定: HEAD)")
    parser.add_argument(
        "--site",
        default=f"https://{DOMAIN}",
        help=f"引く先の URL かディレクトリ (既定: https://{DOMAIN})",
    )
    # **既定は環境から取る** (#818)。literal を既定にしていたので、fork や rename の後に
    # 「他リポジトリの Pages 設定を読んで緑」になり得た。CI は GITHUB_REPOSITORY を
    # 立てるので、literal が効くのは手元だけである
    parser.add_argument(
        "--repo",
        default=os.environ.get("GITHUB_REPOSITORY", "mokume-metal/mokume"),
        help="Pages の設定を読む先 (既定: GITHUB_REPOSITORY)",
    )
    parser.add_argument(
        "--print-site",
        action="store_true",
        help="引く先を出して終わる (ドメインを 2 か所に書かないための口)",
    )
    parser.add_argument(
        "--grace-seconds",
        type=int,
        default=GRACE_SECONDS,
        help="公開が走っている最中を赤にしないための猶予 (秒)",
    )
    parser.add_argument(
        "--skip-domain",
        action="store_true",
        help="GitHub 側の設定との照合を飛ばす (gh の認証が無い手元から追随だけ見るとき)",
    )
    return parser


def main() -> int:
    arguments = build_parser().parse_args()

    if arguments.print_site:
        print(arguments.site)
        return 0

    if arguments.write_stamp is not None:
        path = write_stamp(arguments.write_stamp, arguments.commit or head_commit())
        print(f"印を置いた: {path} ({path.read_text(encoding='utf-8').strip()})")
        return 0

    problems: list[str] = []
    domain_unset = False

    if arguments.skip_domain:
        print("ドメインの照合: 飛ばした (--skip-domain)")
    else:
        found = domain_problems(pages_settings(arguments.repo))
        if found:
            problems.extend(found)
            domain_unset = True
        else:
            print(f"ドメイン: {DOMAIN} が custom domain として入り、HTTPS も要求されている")

    published, reason = read_stamp(arguments.site)
    if reason is not None:
        problems.append(reason)
    else:
        head = head_commit()
        found = freshness_problems(
            published,
            head,
            commits_behind(published, head),
            int(time.time()),
            arguments.grace_seconds,
        )
        problems.extend(found)
        if not found:
            print(f"公開: {arguments.site} は {published[:12]} を配っている (main: {head[:12]})")

    if problems:
        print("公開が追随していない:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        # **手順を出すのは設定が入っていないときだけ。** 追随が遅れているだけの赤に
        # 設定手順を添えると、既に済んでいる作業を毎回勧めることになる
        if domain_unset:
            print(f"\n{SETUP}", file=sys.stderr)
        return 1

    print("ok: 公開は手元の main に追随している")
    return 0


if __name__ == "__main__":
    sys.exit(main())
