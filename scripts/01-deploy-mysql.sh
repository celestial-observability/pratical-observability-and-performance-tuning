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
  - 引数(target_host)に対してMySQLのデプロイする
実行方法:
  - $0 <target_host>
実行例:
  - $0 web
EOF
  exit 2
}

start_timer "$@"
(($# == 1)) || (echo '引数は1つだけ必要です' >&2 && usage)
readonly TARGET_HOST="$1"
ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" 'touch ~/.hushlogin' 2>&1 || {
  log_info "${TARGET_HOST}へのssh失敗($0 $*): "
  exit 0
}

# スキーマファイルのアップロード(上書き)
rsync -az ./schema.sql "$TARGET_HOST":/home/isucon/schema.sql
# スキーマ適用
readonly user="${DB_USER:-isuconp}"
readonly password="${DB_PASSWORD:-isuconp}"
readonly db="${DB_NAME:-isuconp}"
# shellcheck disable=SC2029
ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" "mysqldef --enable-drop -u$user -p$password $db < /home/isucon/schema.sql"

# 設定ファイルのアップロード(上書き)
rsync -az --rsync-path='sudo rsync' ./etc/mysql/mysql.conf.d/mysqld.cnf "$TARGET_HOST":/etc/mysql/mysql.conf.d/mysqld.cnf
# 再起動
ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" 'sudo systemctl restart mysql'

end_timer "$@"
