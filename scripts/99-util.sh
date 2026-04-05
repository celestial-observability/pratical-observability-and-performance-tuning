#!/usr/bin/env bash
set -Eeuo pipefail
#set -x
# -E: 関数やサブシェルでエラーが起きた時トラップ発動
# -e: エラーが発生した時点でスクリプトを終了
# -u: 未定義の変数を使用した場合にエラーを発生
# -x: スクリプトの実行内容を表示(debugで利用)
# -o pipefail: パイプライン内のエラーを検出

log_error() {
  case "$LOG_LEVEL" in
  error | ERROR | info | INFO | debug | DEBUG)
    printf "%s [ERROR] %s\n" "$(date -Iseconds)" "$*" >&2
    ;;
  *)
    # 何もしない
    ;;
  esac
}

log_info() {
  case "$LOG_LEVEL" in
  info | INFO | debug | DEBUG)
    printf "%s [INFO] %s\n" "$(date -Iseconds)" "$*"
    ;;
  *)
    # 何もしない
    ;;
  esac
}

# 時間計測開始
start_timer() {
  EXECUTE_STARTED_UNIX_TIME=$(date +%s)
  readonly EXECUTE_STARTED_UNIX_TIME
  log_info "START: $0 $*"
}

# 時間計測完了
end_timer() {
  EXECUTE_ENDED_UNIX_TIME=$(date +%s)
  readonly EXECUTE_ENDED_UNIX_TIME
  if [[ -n "${EXECUTE_STARTED_UNIX_TIME:-}" ]]; then
    readonly EXECUTE_DIFF_SEC=":$((EXECUTE_ENDED_UNIX_TIME - EXECUTE_STARTED_UNIX_TIME))秒"
  fi
  log_info "END${EXECUTE_DIFF_SEC:-}: $0 $*"
}

err() {
  log_error "error: ${BASH_SOURCE[1]}:${BASH_LINENO[0]}: $BASH_COMMAND"
  exit 1
}
trap err ERR

readonly LOG_LEVEL="${LOG_LEVEL:-info}"
readonly TZ="${TZ:-Asia/Tokyo}"

# ログレベルをバリデーション
case "${LOG_LEVEL}" in
error | ERROR | info | INFO) ;;
*)
  echo "error: LOG_LEVEL='$LOG_LEVEL'はサポートしてません。LOG_LEVEL=error/info/debugを利用してください" >&2
  exit 1
  ;;
esac
