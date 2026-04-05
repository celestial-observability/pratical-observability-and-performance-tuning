#!/usr/bin/env bash
set -Eeuo pipefail
#set -x
# -E: 関数やサブシェルでエラーが起きた時トラップ発動
# -e: エラーが発生した時点でスクリプトを終了
# -u: 未定義の変数を使用した場合にエラーを発生
# -x: スクリプトの実行内容を表示(debugで利用)
# -o pipefail: パイプライン内のエラーを検出

source "$(dirname "$0")/99-util.sh"

usage() {
  cat >&2 <<EOF
$0
概要:
  - 分析用のディレクトリを作成やコードやスロークエリログをダウンロード
実行方法:
  - $0 <target_host> <score>
実行例:
  - $0 web 1234
EOF
  exit 2
}

start_timer "$@"
(($# == 2)) || (echo '引数は2つ必要です' >&2 && usage)
readonly TARGET_HOST="$1"
readonly SCORE="$2"
readonly TMP_BENCH_SCORE_DIR='tmp/bench_score'
mkdir -p ${TMP_BENCH_SCORE_DIR}
ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" "touch ~/.hushlogin" 2>&1 || {
  echo "ssh失敗: $TARGET_HOST"
  exit 0
}

#
# 分析準備
#
mkdir -p "$TMP_BENCH_SCORE_DIR/var/log/nginx"
mkdir -p "$TMP_BENCH_SCORE_DIR/var/log/mysql"

# nginxアクセスログとMySQLのスロークエリログをダウンロード
# ログをOFFにしていて存在しない場合は、ダミーログを使用
if ! rsync -az "$TARGET_HOST":/var/log/nginx/access.log "$TMP_BENCH_SCORE_DIR/var/log/nginx/access.log" 2>/dev/null; then
  log_info "Nginxのアクセスログが見つかりません。ダミーログを使用します。"
  rsync -az "$TARGET_HOST":~/dummy-nginx-access.log "$TMP_BENCH_SCORE_DIR/var/log/nginx/access.log"
fi
if ! rsync -az "$TARGET_HOST":/var/log/mysql/mysql-slow.log "$TMP_BENCH_SCORE_DIR/var/log/mysql/mysql-slow.log" 2>/dev/null; then
  log_info 'MySQLのスロークエリログが見つかりません。ダミーログを使用します。'
  rsync -az "$TARGET_HOST":~/dummy-mysql-slow.log "$TMP_BENCH_SCORE_DIR/var/log/mysql/mysql-slow.log"
fi

# mysql-slow.logから開始時刻を取得する
started_at="$(head -n10 "$TMP_BENCH_SCORE_DIR/var/log/mysql/mysql-slow.log" | grep '# Time: ' | head -n1 | cut -d' ' -f3)"
ended_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if [[ ! -s ./tmp/result.json ]]; then
  jq -n "score: $SCORE" >./tmp/result.json
fi
jq --arg started_at "$started_at" --arg ended_at "$ended_at" '.started_at = $started_at | .ended_at = $ended_at' ./tmp/result.json >$TMP_BENCH_SCORE_DIR/result.json
rm ./tmp/result.json

readonly BENCH_SCORE_DIR="results/${started_at}_score:${SCORE}"
test -e "$BENCH_SCORE_DIR" && log_error "既に同じベンチマーク結果が存在します: $BENCH_SCORE_DIR" && exit 1
rsync -az "$TMP_BENCH_SCORE_DIR/" "$BENCH_SCORE_DIR/"

end_timer "$@"
