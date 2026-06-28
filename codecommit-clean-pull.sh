#!/usr/bin/env bash
#
# codecommit-clean-pull.sh
# ========================
# EC2 (RHEL 9.6) 上に clone 済みの CodeCommit リポジトリを、
# リモートの指定ブランチ（既定: main）の最新版に「完全同期」するスクリプトです。
#
# 「完全同期」とは:
#   - ローカルでの編集（tracked ファイルの変更）をすべて破棄
#   - 管理対象外（untracked）のファイル・ディレクトリをすべて削除
#   - （既定では）.gitignore で無視されているファイルも削除
#   - 進行中の merge / rebase / cherry-pick 等を中断
#   - ローカルブランチをリモートの先頭コミットに hard reset
#   - submodule があれば再帰的に同期・クリーンアップ
#   => 結果として、対象ディレクトリ配下は「リモート main を新規 clone した直後」
#      と同じクリーンな状態になります。
#
# 認証について:
#   - 本スクリプトは「すでに clone 済み」のリポジトリに対して fetch するため、
#     origin の URL と Git 資格情報ヘルパ（git-remote-codecommit / HTTPS+IAM 等）が
#     設定済みであることを前提とします。
#   - grc(git-remote-codecommit) 形式の remote（codecommit::<region>://<repo>）の場合は
#     aws CLI / git-remote-codecommit が必要です。
#
# 依存: bash, git （grc remote の場合は aws, git-remote-codecommit）
# 共通部品: common.sh （log_info / log_success / log_warn / log_error / die / run /
#           confirm / require_command）
#   - log_info / log_success は stdout、log_warn / log_error は stderr に出力します。
#   - common.sh には log_debug が無いため、本スクリプトでローカルに定義します（DEBUG=true で有効）。
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 0. 共通部品(common.sh)の読み込み
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

if [[ ! -f "${SCRIPT_DIR}/common.sh" ]]; then
  echo "[${SCRIPT_NAME}][ERROR] common.sh が見つかりません: ${SCRIPT_DIR}/common.sh" >&2
  exit 1
fi
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# common.sh には log_debug が無いため、DEBUG=true のときだけ stderr に出力する
# デバッグログヘルパをローカル定義する（色は common.sh の定義を流用）。
log_debug() {
  [[ "${DEBUG:-false}" == "true" ]] || return 0
  printf '%s[DEBUG]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
}

# ---------------------------------------------------------------------------
# 1. 既定値
# ---------------------------------------------------------------------------
REPO_DIR=""                 # clone 済みディレクトリ（必須）
BRANCH="main"               # 同期対象ブランチ
REMOTE="origin"             # リモート名
REPO_NAME=""                # （任意）CodeCommit リポジトリ名。remote URL の検証に使う
REGION=""                   # （任意）AWS リージョン。grc remote 利用時などに export する
KEEP_IGNORED="false"        # true の場合 .gitignore 無視ファイルは残す（git clean に -x を付けない）
SYNC_SUBMODULES="true"      # true の場合 submodule も再帰的に同期・クリーン
DRY_RUN="false"             # true の場合は破壊的操作を行わず、何が起きるかだけ表示
ASSUME_YES="false"          # true の場合は対話確認をスキップ
DEBUG="${DEBUG:-false}"     # true の場合 log_debug を有効化（上で定義したローカル関数が参照）
export DEBUG

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${SCRIPT_NAME} --repo-dir <path> [オプション]

説明:
  clone 済みの CodeCommit リポジトリを、リモートの指定ブランチ（既定: ${BRANCH}）の
  最新版に完全同期します。ローカルの変更・未管理ファイル・無視ファイルをすべて
  クリーンアップしてから hard reset するため、ローカルの編集は失われます。

必須:
  --repo-dir   <path>     clone 済みディレクトリの絶対パス

オプション:
  --branch     <name>     同期対象ブランチ (既定: ${BRANCH})
  --remote     <name>     リモート名 (既定: ${REMOTE})
  --repo-name  <name>     CodeCommit リポジトリ名。remote URL に含まれるか検証する (任意)
  --region     <region>   AWS リージョン。AWS_DEFAULT_REGION として export する (任意)
  --keep-ignored          .gitignore で無視されているファイルは削除しない (既定: 削除する)
  --no-submodules         submodule の同期・クリーンを行わない (既定: 行う)
  --dry-run               破壊的操作を行わず、変更内容・削除対象を表示するだけ
  -y, --yes               破壊的操作の前の対話確認をスキップする
  --debug                 デバッグログを出力する
  -h, --help              このヘルプを表示

例:
  # ドライラン（何が消えるか・何が変わるかを確認）
  ./${SCRIPT_NAME} --repo-dir /opt/app/my-repo --dry-run

  # 実行（CI/cron など非対話環境では -y を付ける）
  ./${SCRIPT_NAME} --repo-dir /opt/app/my-repo --branch main --yes

  # リポジトリ名・リージョンを検証しつつ実行
  ./${SCRIPT_NAME} --repo-dir /opt/app/my-repo --repo-name my-repo \\
    --region ap-northeast-1 --yes

終了コード:
  0  成功（リモートと完全一致）
  1  エラー
  2  --dry-run で差分（変更 or 削除対象）あり
USAGE
}

# ---------------------------------------------------------------------------
# 3. 引数パース
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --repo-dir)      REPO_DIR="${2:-}"; shift 2 ;;
      --branch)        BRANCH="${2:-}"; shift 2 ;;
      --remote)        REMOTE="${2:-}"; shift 2 ;;
      --repo-name)     REPO_NAME="${2:-}"; shift 2 ;;
      --region)        REGION="${2:-}"; shift 2 ;;
      --keep-ignored)  KEEP_IGNORED="true"; shift 1 ;;
      --no-submodules) SYNC_SUBMODULES="false"; shift 1 ;;
      --dry-run)       DRY_RUN="true"; shift 1 ;;
      -y|--yes)        ASSUME_YES="true"; shift 1 ;;
      --debug)         DEBUG="true"; export DEBUG; shift 1 ;;
      -h|--help)       usage; exit 0 ;;
      *)               usage; die "不明なオプションです: ${1}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 4. 入力検証
# ---------------------------------------------------------------------------
validate_inputs() {
  [[ -n "${REPO_DIR}" ]] || { usage; die "--repo-dir は必須です。"; }
  [[ -d "${REPO_DIR}" ]] || die "指定ディレクトリが存在しません: ${REPO_DIR}"
  [[ -n "${BRANCH}" ]]   || die "--branch が空です。"
  [[ -n "${REMOTE}" ]]   || die "--remote が空です。"

  # 絶対パスに正規化（以降の安全確認のため）
  REPO_DIR="$(cd "${REPO_DIR}" && pwd)"

  # ルートディレクトリなど明らかに危険なパスを拒否（git clean の暴発防止）
  case "${REPO_DIR}" in
    "/"|"")   die "危険なパスのため中止します: '${REPO_DIR}'" ;;
  esac
}

# ---------------------------------------------------------------------------
# 5. git ラッパ
#   - 常に対象ディレクトリ(-C)で実行
#   - safe.directory を都度指定し、所有者違い(dubious ownership)エラーを回避
#     （global 設定を書き換えないため副作用がない）
# ---------------------------------------------------------------------------
git_r() {
  git -C "${REPO_DIR}" -c "safe.directory=${REPO_DIR}" "$@"
}

# ---------------------------------------------------------------------------
# 6. 前提確認 / リポジトリ確認
# ---------------------------------------------------------------------------
preflight() {
  # git が無ければ即終了（RHEL なら: sudo dnf install -y git）
  require_command git

  # AWS リージョン指定があれば export（grc remote / aws CLI 用）
  if [[ -n "${REGION}" ]]; then
    export AWS_DEFAULT_REGION="${REGION}"
    export AWS_REGION="${REGION}"
    log_debug "AWS リージョンを設定: ${REGION}"
  fi

  # Git リポジトリであることを確認
  if ! git_r rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "Git の作業ツリーではありません: ${REPO_DIR}"
  fi

  # 作業ツリーの最上位（トップレベル）を取得し、そこを対象にする
  local toplevel
  toplevel="$(git_r rev-parse --show-toplevel)"
  if [[ "${toplevel}" != "${REPO_DIR}" ]]; then
    log_warn "指定ディレクトリは Git のトップレベルではありません。トップレベルを対象にします。"
    log_warn "  指定        : ${REPO_DIR}"
    log_warn "  トップレベル: ${toplevel}"
    REPO_DIR="${toplevel}"
  fi
  log_info "対象リポジトリ: ${REPO_DIR}"

  # remote の存在確認
  if ! git_r remote get-url "${REMOTE}" >/dev/null 2>&1; then
    die "リモート '${REMOTE}' が設定されていません。git remote -v で確認してください。"
  fi
  local remote_url
  remote_url="$(git_r remote get-url "${REMOTE}")"
  log_info "リモート ${REMOTE}: ${remote_url}"

  # 指定された CodeCommit リポジトリ名が remote URL に含まれるか検証（任意）
  if [[ -n "${REPO_NAME}" ]]; then
    if [[ "${remote_url}" != *"${REPO_NAME}"* ]]; then
      die "リモート URL に指定リポジトリ名 '${REPO_NAME}' が含まれていません。対象ディレクトリ/リポジトリの取り違えの可能性があります。URL: ${remote_url}"
    fi
    log_debug "リポジトリ名の検証 OK: '${REPO_NAME}' は remote URL に含まれています。"
  fi

  # grc(git-remote-codecommit)形式の remote なら依存コマンドを確認
  if [[ "${remote_url}" == codecommit::* ]]; then
    # aws CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
    require_command aws
    # git-remote-codecommit: pip install git-remote-codecommit
    require_command git-remote-codecommit
    log_debug "grc 形式の remote を検出しました（aws / git-remote-codecommit 確認済み）。"
  fi
}

# ---------------------------------------------------------------------------
# 7. リモート最新の取得
# ---------------------------------------------------------------------------
fetch_remote() {
  log_info "リモートから fetch します（${REMOTE}, --prune --tags）..."
  if ! git_r fetch --prune --tags "${REMOTE}"; then
    die "fetch に失敗しました。ネットワーク / 認証（git-remote-codecommit, IAM 権限 codecommit:GitPull 等）を確認してください。"
  fi

  # リモート追跡ブランチの存在確認
  if ! git_r rev-parse --verify --quiet "refs/remotes/${REMOTE}/${BRANCH}" >/dev/null; then
    die "リモートブランチ '${REMOTE}/${BRANCH}' が見つかりません。--branch / --remote を確認してください。"
  fi
  local remote_head
  remote_head="$(git_r rev-parse "${REMOTE}/${BRANCH}")"
  log_info "リモート ${REMOTE}/${BRANCH} の最新コミット: ${remote_head:0:12}"
}

# ---------------------------------------------------------------------------
# 8. git clean のフラグを組み立てる
#    -ffd : 未管理ファイル/ディレクトリ + ネストした git リポジトリも削除
#    -x   : .gitignore で無視されたファイルも削除（--keep-ignored で外す）
# ---------------------------------------------------------------------------
clean_flags() {
  if [[ "${KEEP_IGNORED}" == "true" ]]; then
    printf '%s' "-ffd"
  else
    printf '%s' "-ffdx"
  fi
}

# ---------------------------------------------------------------------------
# 9. ドライラン: 何が変わるか / 何が消えるかを表示する
# ---------------------------------------------------------------------------
show_dry_run() {
  local cflags
  cflags="$(clean_flags)"

  log_info "=== DRY-RUN（実際の変更は行いません） ==="

  # 現在の作業ツリーの変更（tracked の変更 + untracked）
  log_info "--- 現在の作業ツリーの状態 (git status --short) ---"
  git_r status --short || true

  # ローカル HEAD とリモートの差分
  log_info "--- HEAD と ${REMOTE}/${BRANCH} のコミット差分 (git log) ---"
  if git_r rev-parse --verify --quiet HEAD >/dev/null; then
    git_r --no-pager log --oneline --left-right "HEAD...${REMOTE}/${BRANCH}" || true
    log_info "--- ファイル単位の差分サマリ (git diff --stat) ---"
    git_r --no-pager diff --stat "HEAD" "${REMOTE}/${BRANCH}" || true
  else
    log_warn "HEAD が存在しません（空リポジトリ?）。"
  fi

  # git clean で削除される対象
  log_info "--- git clean ${cflags} で削除される対象 (-n: 実際には消さない) ---"
  git_r clean ${cflags} -n || true

  # 差分があれば終了コード 2 を返すための判定
  local dirty="false"
  if [[ -n "$(git_r status --porcelain)" ]]; then dirty="true"; fi
  if git_r rev-parse --verify --quiet HEAD >/dev/null; then
    if [[ "$(git_r rev-parse HEAD)" != "$(git_r rev-parse "${REMOTE}/${BRANCH}")" ]]; then
      dirty="true"
    fi
  fi

  if [[ "${dirty}" == "true" ]]; then
    log_warn "DRY-RUN: リモートとの差分（変更 or 削除対象）があります。実行すると上記がクリーンアップされます。"
    exit 2
  fi
  log_info "DRY-RUN: 既にリモートと一致しています。実行しても変化はありません。"
  exit 0
}

# ---------------------------------------------------------------------------
# 10. 進行中の操作（merge / rebase / cherry-pick / revert / am）を中断する
#     これらが残っていると checkout/reset が失敗するため、念のため中断する。
# ---------------------------------------------------------------------------
abort_in_progress() {
  local git_dir
  git_dir="$(git_r rev-parse --git-dir)"
  # git_dir が相対パスの場合は REPO_DIR からの相対なので結合
  case "${git_dir}" in
    /*) : ;;
    *)  git_dir="${REPO_DIR}/${git_dir}" ;;
  esac

  if git_r rev-parse --verify --quiet MERGE_HEAD >/dev/null; then
    log_warn "進行中の merge を中断します。"
    git_r merge --abort || true
  fi
  if [[ -d "${git_dir}/rebase-merge" || -d "${git_dir}/rebase-apply" ]]; then
    log_warn "進行中の rebase を中断します。"
    git_r rebase --abort || true
  fi
  if [[ -f "${git_dir}/CHERRY_PICK_HEAD" ]]; then
    log_warn "進行中の cherry-pick を中断します。"
    git_r cherry-pick --abort || true
  fi
  if [[ -f "${git_dir}/REVERT_HEAD" ]]; then
    log_warn "進行中の revert を中断します。"
    git_r revert --abort || true
  fi
  if [[ -d "${git_dir}/rebase-apply" ]]; then
    # am の途中状態（rebase-apply）も念のため
    git_r am --abort >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# 11. クリーン同期の本体
# ---------------------------------------------------------------------------
do_sync() {
  local cflags
  cflags="$(clean_flags)"

  local old_head
  old_head="$(git_r rev-parse HEAD 2>/dev/null || echo '(none)')"

  # 進行中操作の中断
  abort_in_progress

  # ローカルブランチをリモート追跡ブランチに作成/付け替えしつつチェックアウト。
  # -f: ローカル変更を破棄して強制チェックアウト
  # -B: ブランチが存在してもリモート先頭にリセットして作成
  log_info "ブランチ '${BRANCH}' を ${REMOTE}/${BRANCH} に強制チェックアウトします..."
  if ! git_r checkout -f -B "${BRANCH}" --track "${REMOTE}/${BRANCH}"; then
    die "checkout に失敗しました。"
  fi

  # 念のため hard reset でリモート先頭に完全一致させる
  log_info "hard reset で ${REMOTE}/${BRANCH} に合わせます..."
  git_r reset --hard "${REMOTE}/${BRANCH}"

  # 未管理ファイル/ディレクトリ（および既定では無視ファイル）を削除
  log_info "未管理ファイル/ディレクトリを削除します (git clean ${cflags})..."
  git_r clean ${cflags}

  # submodule の同期・クリーン
  if [[ "${SYNC_SUBMODULES}" == "true" && -f "${REPO_DIR}/.gitmodules" ]]; then
    log_info "submodule を再帰的に同期・クリーンします..."
    git_r submodule sync --recursive || true
    git_r submodule update --init --recursive --force || true
    # 各 submodule 内も同様にクリーンアップ
    git_r submodule foreach --recursive \
      "git reset --hard && git clean ${cflags}" || true
  fi

  local new_head
  new_head="$(git_r rev-parse HEAD)"

  log_info "同期前 HEAD: ${old_head:0:12}"
  log_info "同期後 HEAD: ${new_head:0:12}"
}

# ---------------------------------------------------------------------------
# 12. 検証: リモートと完全一致しているか
# ---------------------------------------------------------------------------
verify_synced() {
  local local_head remote_head status_out
  local_head="$(git_r rev-parse HEAD)"
  remote_head="$(git_r rev-parse "${REMOTE}/${BRANCH}")"

  if [[ "${local_head}" != "${remote_head}" ]]; then
    die "検証失敗: HEAD(${local_head:0:12}) が ${REMOTE}/${BRANCH}(${remote_head:0:12}) と一致しません。"
  fi

  status_out="$(git_r status --porcelain)"
  if [[ -n "${status_out}" ]]; then
    log_error "検証失敗: 作業ツリーがクリーンではありません:"
    printf '%s\n' "${status_out}" >&2
    die "クリーンアップが完了していません。"
  fi

  log_info "検証 OK: 作業ツリーはクリーンで、${REMOTE}/${BRANCH} と完全一致しています。"
}

# ---------------------------------------------------------------------------
# 13. メイン
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_inputs
  preflight
  fetch_remote

  # ドライランはここで終了（show_dry_run 内で exit）
  if [[ "${DRY_RUN}" == "true" ]]; then
    show_dry_run
  fi

  # 破壊的操作の確認
  local cflags
  cflags="$(clean_flags)"
  log_warn "これからローカルの変更・未管理ファイルをすべて破棄して ${REMOTE}/${BRANCH} に同期します。"
  log_warn "  対象ディレクトリ: ${REPO_DIR}"
  if [[ "${KEEP_IGNORED}" == "true" ]]; then
    log_warn "  git clean フラグ: ${cflags}（.gitignore 無視ファイルは残す）"
  else
    log_warn "  git clean フラグ: ${cflags}（-x 付き = .gitignore 無視ファイルも削除）"
  fi
  if [[ "${ASSUME_YES}" != "true" ]]; then
    if [[ -t 0 ]]; then
      if ! confirm "本当に実行しますか?"; then
        die "ユーザーによって中止されました。"
      fi
    else
      die "非対話環境です。意図しない破壊を防ぐため、実行するには -y/--yes を指定してください（確認には --dry-run）。"
    fi
  fi

  do_sync
  verify_synced

  log_info "完了: ${REPO_DIR} を ${REMOTE}/${BRANCH} の最新版にクリーン同期しました。"
}

main "$@"
