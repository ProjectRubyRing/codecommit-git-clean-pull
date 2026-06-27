#!/usr/bin/env bash
#
# common.sh
# =========
# 複数のシェルスクリプトから source して使う「共通部品」です。
# 主にロギング・前提コマンド確認・対話確認などの汎用ヘルパを提供します。
#
# 使い方（呼び出し側スクリプト）:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=common.sh
#   source "${SCRIPT_DIR}/common.sh"
#
# このファイルが提供する公開インターフェース（呼び出し側が依存してよい関数）:
#   log_info   <msg...>          : 情報ログ（stderr, 緑）
#   log_warn   <msg...>          : 警告ログ（stderr, 黄）
#   log_error  <msg...>          : エラーログ（stderr, 赤）
#   log_debug  <msg...>          : デバッグログ（DEBUG=true のときだけ stderr に出力）
#   die        <msg...>          : エラーを出して exit 1
#   require_cmd <name> [hint]    : コマンドが PATH に無ければ die
#   confirm    <prompt>          : y/N の対話確認（yes なら 0、no なら 1 を返す）
#
# 環境変数:
#   DEBUG=true            : log_debug を有効化
#   NO_COLOR=1            : 色付けを無効化（出力先が非 TTY の場合も自動で無効）
#   COMMON_LOG_PREFIX     : ログ行の先頭に付けるプレフィックス（既定: 呼び出し元スクリプト名）
#
# 注意:
#   - すべてのログは stderr に出力します（stdout はスクリプト本来の出力専用にするため）。
#   - 認証情報など秘匿値は絶対にログに出さないでください（このファイルでは出しません）。
#

# 二重 source による再定義を避けるためのガード
if [[ -n "${__COMMON_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__COMMON_SH_LOADED=1
COMMON_SH_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# 色設定
#   - 出力先(stderr)が端末でない、または NO_COLOR が設定されている場合は無効化
# ---------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  __C_RESET="$(printf '\033[0m')"
  __C_RED="$(printf '\033[31m')"
  __C_GREEN="$(printf '\033[32m')"
  __C_YELLOW="$(printf '\033[33m')"
  __C_GRAY="$(printf '\033[90m')"
else
  __C_RESET=""; __C_RED=""; __C_GREEN=""; __C_YELLOW=""; __C_GRAY=""
fi

# ログ行の先頭プレフィックス（既定は呼び出し元スクリプト名）
__log_prefix() {
  local p="${COMMON_LOG_PREFIX:-$(basename "${0}")}"
  printf '[%s]' "${p}"
}

# ---------------------------------------------------------------------------
# ロギング関数（すべて stderr）
# ---------------------------------------------------------------------------
log_info() {
  printf '%s %sINFO%s  %s\n' "$(__log_prefix)" "${__C_GREEN}" "${__C_RESET}" "$*" >&2
}

log_warn() {
  printf '%s %sWARN%s  %s\n' "$(__log_prefix)" "${__C_YELLOW}" "${__C_RESET}" "$*" >&2
}

log_error() {
  printf '%s %sERROR%s %s\n' "$(__log_prefix)" "${__C_RED}" "${__C_RESET}" "$*" >&2
}

log_debug() {
  if [[ "${DEBUG:-false}" == "true" ]]; then
    printf '%s %sDEBUG%s %s\n' "$(__log_prefix)" "${__C_GRAY}" "${__C_RESET}" "$*" >&2
  fi
}

# エラーを出して終了
die() {
  log_error "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# 前提コマンドの存在確認
#   require_cmd git "git をインストールしてください"
# ---------------------------------------------------------------------------
require_cmd() {
  local cmd="${1:?require_cmd: コマンド名が必要です}"
  local hint="${2:-}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    if [[ -n "${hint}" ]]; then
      die "必要なコマンドが見つかりません: ${cmd} （${hint}）"
    else
      die "必要なコマンドが見つかりません: ${cmd}"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 対話確認（y/N）
#   confirm "本当に実行しますか?" && do_something
#   - 非 TTY の場合は false を返す（呼び出し側で --yes 等を別途用意すること）
# ---------------------------------------------------------------------------
confirm() {
  local prompt="${1:-続行しますか?}"
  if [[ ! -t 0 ]]; then
    return 1
  fi
  local ans=""
  printf '%s %s [y/N]: ' "$(__log_prefix)" "${prompt}" >&2
  read -r ans || true
  case "${ans}" in
    y|Y|yes|YES) return 0 ;;
    *)           return 1 ;;
  esac
}
