#!/usr/bin/env bash
#
# helpers/clean-pull.sh
# =====================
# codecommit-clean-pull.sh のラッパー（ヘルパー）スクリプトです。
#
# 目的:
#   本体スクリプト（codecommit-clean-pull.sh）は指定パラメータが多いため、
#   環境ごとに固定できる値を本ファイルの「設定セクション」にまとめて定義し、
#   毎回コンソールから指定する引数を最小限にします。
#
# 使い方（例）:
#   # 設定セクションの DEFAULT_REPO_DIR を設定済みなら引数なしで実行できる
#   ./helpers/clean-pull.sh
#
#   # リポジトリディレクトリだけ都度指定する場合
#   ./helpers/clean-pull.sh /opt/app/my-repo
#
#   # まず dry-run で確認してから本実行
#   ./helpers/clean-pull.sh -n /opt/app/my-repo
#   ./helpers/clean-pull.sh -y /opt/app/my-repo
#
# スイッチロール（source）の扱いについて:
#   スイッチロール用シェルの source は「本体スクリプトのプロセス内」で行われます
#   （本体の --auto-switch-role / --switch-role-script 機能を利用）。
#   そのため、本ヘルパーは以下を保証します。
#     (1) スイッチロール用シェルのパスを絶対パスに解決してから本体へ渡す
#         （カレントディレクトリがどこであっても source が失敗しない）
#     (2) 本体スクリプト自体は source せず、子プロセスとして実行する
#         （本体は set -e / exit を使うため、source すると呼び出し元シェルが落ちる）
#     (3) 本ヘルパー自体も source での実行を禁止する（誤用ガード）
#   スイッチロール後の認証情報は本体プロセス内で fetch に使われるため、
#   この方式でロール切り替えは正常に機能します。
#   ※呼び出し元シェルに認証情報を残したい場合のみ、従来どおり手動で
#     `source <スイッチロール用シェル>` を実行してください。
#
# 本体スクリプトのパス解決について:
#   本ヘルパーは helpers/ 配下に置かれる前提で、既定では「自分の 1 つ上の
#   ディレクトリ」にある codecommit-clean-pull.sh を呼び出します。
#   配置を変える場合は設定セクションの MAIN_SCRIPT を変更するか、
#   環境変数 CLEAN_PULL_MAIN_SCRIPT で上書きしてください。
#   本体は自身の場所（BASH_SOURCE）を基準に common.sh を source するため、
#   ヘルパーがどこから実行されても common.sh の読み込みは正常に動作します。
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 0. source 誤用ガード
#    本ヘルパーは「実行」専用です。source されると exit が呼び出し元の
#    シェルを終了させてしまうため、最初に検出して中断します。
# ---------------------------------------------------------------------------
if (return 0 2>/dev/null); then
  echo "[clean-pull.sh][ERROR] このヘルパーは source ではなく実行してください: ./clean-pull.sh" >&2
  echo "[clean-pull.sh][ERROR] スイッチロールの source は本体スクリプト内で自動的に行われます。" >&2
  return 1
fi

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_NAME="$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# 1. 設定セクション（環境に合わせて自由に固定値を追加・変更してください）
#    すべて環境変数で上書き可能です（例: CLEAN_PULL_BRANCH=develop ./clean-pull.sh）。
# ---------------------------------------------------------------------------

# 本体スクリプトのパス（既定: ヘルパーの 1 つ上のディレクトリ）
MAIN_SCRIPT="${CLEAN_PULL_MAIN_SCRIPT:-${HELPER_DIR}/../codecommit-clean-pull.sh}"

# 同期対象リポジトリのディレクトリ。ここに固定値を設定すれば引数なしで実行できる。
# 空のままの場合は、引数（-r <path> または第 1 位置引数）での指定が必須になる。
DEFAULT_REPO_DIR="${CLEAN_PULL_REPO_DIR:-}"

# 同期対象ブランチ / リモート名
DEFAULT_BRANCH="${CLEAN_PULL_BRANCH:-main}"
DEFAULT_REMOTE="${CLEAN_PULL_REMOTE:-origin}"

# CodeCommit リポジトリ名（remote URL の検証に使用。空なら検証しない）
DEFAULT_REPO_NAME="${CLEAN_PULL_REPO_NAME:-}"

# AWS リージョン（空なら本体に渡さない）
DEFAULT_REGION="${CLEAN_PULL_REGION:-ap-northeast-1}"

# スイッチロール用シェル（別チーム提供）のパス。
#   - 相対パスで書いた場合は「このヘルパーのディレクトリ」基準で解決する。
#   - 空の場合はスイッチロール関連オプションを本体に渡さない
#     （権限が無ければ本体が手動スイッチロールの案内を出して終了する）。
SWITCH_ROLE_SCRIPT="${CLEAN_PULL_SWITCH_ROLE_SCRIPT:-}"

# CodeCommit 権限が無いときに自動でスイッチロールするか（true/false）。
# true の場合は SWITCH_ROLE_SCRIPT の設定が必須。
AUTO_SWITCH_ROLE="${CLEAN_PULL_AUTO_SWITCH_ROLE:-true}"

# .gitignore で無視されているファイルを残すか（true で本体に --keep-ignored を付与）
KEEP_IGNORED="${CLEAN_PULL_KEEP_IGNORED:-false}"

# submodule の同期を行わないか（true で本体に --no-submodules を付与）
NO_SUBMODULES="${CLEAN_PULL_NO_SUBMODULES:-false}"

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${HELPER_NAME} [オプション] [<repo-dir>]

説明:
  codecommit-clean-pull.sh のラッパーです。環境固有の固定値（ブランチ、
  リージョン、スイッチロール用シェルのパス等）は本ヘルパー冒頭の
  設定セクションに定義済みのため、通常は最小限の引数で実行できます。

引数:
  <repo-dir>              同期対象の clone 済みディレクトリ。
                          設定セクションの DEFAULT_REPO_DIR が空の場合は必須。
                          （-r オプションでも指定可能）

オプション:
  -r <path>               同期対象ディレクトリ（位置引数の代わりに使用可）
  -b <branch>             同期対象ブランチ (既定: ${DEFAULT_BRANCH})
  -n, --dry-run           破壊的操作を行わず、変更内容・削除対象の表示のみ
  -y, --yes               破壊的操作の前の対話確認をスキップ（CI/cron 用）
  --debug                 デバッグログを出力する
  -h, --help              このヘルプを表示
  -- <args...>            以降の引数をそのまま本体スクリプトへ引き渡す
                          （本ヘルパーが対応していないオプションを使いたい場合）

現在の設定値（設定セクション / 環境変数で変更可能）:
  本体スクリプト        : ${MAIN_SCRIPT}
  リポジトリディレクトリ: ${DEFAULT_REPO_DIR:-（未設定: 引数で指定してください）}
  ブランチ / リモート   : ${DEFAULT_BRANCH} / ${DEFAULT_REMOTE}
  リポジトリ名検証      : ${DEFAULT_REPO_NAME:-（検証しない）}
  AWS リージョン        : ${DEFAULT_REGION:-（指定しない）}
  スイッチロール用シェル: ${SWITCH_ROLE_SCRIPT:-（未設定）}
  自動スイッチロール    : ${AUTO_SWITCH_ROLE}

例:
  # まず dry-run で影響範囲を確認
  ./${HELPER_NAME} -n /opt/app/my-repo

  # 本実行（非対話環境では -y 必須）
  ./${HELPER_NAME} -y /opt/app/my-repo

  # ブランチを変えて実行
  ./${HELPER_NAME} -b develop -y /opt/app/my-repo

  # 本体のオプションを直接渡す
  ./${HELPER_NAME} /opt/app/my-repo -- --skip-aws-check

終了コード（本体スクリプトの終了コードをそのまま返します）:
  0  成功（リモートと完全一致）
  1  エラー（引数不正を含む）
  2  --dry-run で差分（変更 or 削除対象）あり
USAGE
}

err() { echo "[${HELPER_NAME}][ERROR] $*" >&2; }

# ---------------------------------------------------------------------------
# 3. パスユーティリティ
#    相対パスを絶対パスへ解決する（source 対象のパスずれ防止のため必須）。
# ---------------------------------------------------------------------------

# usage: to_abs <path> <相対パスの基準ディレクトリ>
to_abs() {
  local path="$1" base="$2"
  case "${path}" in
    /*) printf '%s' "${path}" ;;
    *)  printf '%s' "${base}/${path}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 4. 引数パース
# ---------------------------------------------------------------------------
REPO_DIR="${DEFAULT_REPO_DIR}"
BRANCH="${DEFAULT_BRANCH}"
DRY_RUN="false"
ASSUME_YES="false"
DEBUG_FLAG="false"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "${1}" in
    -r)           [[ -n "${2:-}" ]] || { usage; err "-r には値が必要です。"; exit 1; }
                  REPO_DIR="${2}"; shift 2 ;;
    -b)           [[ -n "${2:-}" ]] || { usage; err "-b には値が必要です。"; exit 1; }
                  BRANCH="${2}"; shift 2 ;;
    -n|--dry-run) DRY_RUN="true"; shift 1 ;;
    -y|--yes)     ASSUME_YES="true"; shift 1 ;;
    --debug)      DEBUG_FLAG="true"; shift 1 ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; EXTRA_ARGS=("$@"); break ;;
    -*)           usage; err "不明なオプションです: ${1}（本体のオプションは -- 以降に指定してください）"; exit 1 ;;
    *)            if [[ -n "${REPO_DIR}" && "${REPO_DIR}" != "${DEFAULT_REPO_DIR}" ]]; then
                    usage; err "リポジトリディレクトリが複数指定されています: '${REPO_DIR}' と '${1}'"; exit 1
                  fi
                  REPO_DIR="${1}"; shift 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 5. 引数・設定の検証
# ---------------------------------------------------------------------------

# 必須: リポジトリディレクトリ（設定セクションにも引数にも無ければエラー）
if [[ -z "${REPO_DIR}" ]]; then
  usage
  err "同期対象ディレクトリが指定されていません。"
  err "引数 <repo-dir>（または -r <path>）で指定するか、設定セクションの DEFAULT_REPO_DIR を設定してください。"
  exit 1
fi
# 実行時のカレントディレクトリ基準で絶対パス化
REPO_DIR="$(to_abs "${REPO_DIR}" "$(pwd)")"
if [[ ! -d "${REPO_DIR}" ]]; then
  err "同期対象ディレクトリが存在しません: ${REPO_DIR}"
  exit 1
fi

[[ -n "${BRANCH}" ]] || { usage; err "-b（ブランチ名）が空です。"; exit 1; }

# 本体スクリプトの存在確認（ヘルパー基準の相対パスを絶対パス化してから検証）
MAIN_SCRIPT="$(to_abs "${MAIN_SCRIPT}" "${HELPER_DIR}")"
if [[ ! -f "${MAIN_SCRIPT}" ]]; then
  err "本体スクリプトが見つかりません: ${MAIN_SCRIPT}"
  err "設定セクションの MAIN_SCRIPT、または環境変数 CLEAN_PULL_MAIN_SCRIPT を確認してください。"
  exit 1
fi
# 本体は自身の隣の common.sh を source するため、ここで事前確認しておく
if [[ ! -f "$(dirname "${MAIN_SCRIPT}")/common.sh" ]]; then
  err "本体スクリプトと同じディレクトリに common.sh が見つかりません: $(dirname "${MAIN_SCRIPT}")/common.sh"
  exit 1
fi

# スイッチロール用シェル: 相対パスはヘルパーのディレクトリ基準で絶対パス化する。
# こうすることで、どこから実行しても本体内の source が同じファイルを読み込む。
if [[ -n "${SWITCH_ROLE_SCRIPT}" ]]; then
  SWITCH_ROLE_SCRIPT="$(to_abs "${SWITCH_ROLE_SCRIPT}" "${HELPER_DIR}")"
  if [[ ! -f "${SWITCH_ROLE_SCRIPT}" ]]; then
    err "スイッチロール用シェルが見つかりません: ${SWITCH_ROLE_SCRIPT}"
    err "設定セクションの SWITCH_ROLE_SCRIPT、または環境変数 CLEAN_PULL_SWITCH_ROLE_SCRIPT を確認してください。"
    exit 1
  fi
elif [[ "${AUTO_SWITCH_ROLE}" == "true" ]]; then
  err "AUTO_SWITCH_ROLE=true ですが SWITCH_ROLE_SCRIPT が未設定です。"
  err "設定セクションの SWITCH_ROLE_SCRIPT にスイッチロール用シェルのパスを設定するか、"
  err "自動スイッチロールを使わない場合は AUTO_SWITCH_ROLE=false にしてください。"
  exit 1
fi

# ---------------------------------------------------------------------------
# 6. 本体スクリプトへ渡す引数の組み立て
# ---------------------------------------------------------------------------
ARGS=(
  --repo-dir "${REPO_DIR}"
  --branch   "${BRANCH}"
  --remote   "${DEFAULT_REMOTE}"
)
[[ -n "${DEFAULT_REPO_NAME}" ]] && ARGS+=(--repo-name "${DEFAULT_REPO_NAME}")
[[ -n "${DEFAULT_REGION}"    ]] && ARGS+=(--region "${DEFAULT_REGION}")
[[ "${KEEP_IGNORED}"  == "true" ]] && ARGS+=(--keep-ignored)
[[ "${NO_SUBMODULES}" == "true" ]] && ARGS+=(--no-submodules)
[[ "${DRY_RUN}"       == "true" ]] && ARGS+=(--dry-run)
[[ "${ASSUME_YES}"    == "true" ]] && ARGS+=(--yes)
[[ "${DEBUG_FLAG}"    == "true" ]] && ARGS+=(--debug)
if [[ -n "${SWITCH_ROLE_SCRIPT}" ]]; then
  ARGS+=(--switch-role-script "${SWITCH_ROLE_SCRIPT}")
  [[ "${AUTO_SWITCH_ROLE}" == "true" ]] && ARGS+=(--auto-switch-role)
fi
ARGS+=("${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}")

# ---------------------------------------------------------------------------
# 7. 実行
#    本体は source せず子プロセスとして実行する（本体の set -e / exit から
#    呼び出し元シェルを保護する）。スイッチロール用シェルの source は
#    本体プロセス内（do_switch_role）で行われ、その認証情報は同一プロセス
#    内の fetch にそのまま使われるため、この方式で正常に機能する。
#    exec により本体の終了コード（0/1/2）をそのまま返す。
# ---------------------------------------------------------------------------
echo "[${HELPER_NAME}] 実行: bash ${MAIN_SCRIPT} ${ARGS[*]}"
exec bash "${MAIN_SCRIPT}" "${ARGS[@]}"
