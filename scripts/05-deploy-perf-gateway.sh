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
  - 引数(agent_host, gateway_host)に対してパフォーマンス用のデプロイ
実行方法:
  - $0 <target_host>
実行例:
  - $0 web
EOF
  exit 2
}

# docker composeをデプロイ & 再起動
# ClickHouseがキモなのでデプロイ後、接続確認をする
deploy_perf_servers() {
  ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" '
  set -euo pipefail

  mkdir -p ~/etc ~/var
  docker compose down 2>/dev/null || true
  '

  rsync -az ./etc/grafana "$TARGET_HOST":~/etc/
  rsync -az ./etc/clickhouse-server "$TARGET_HOST":~/etc/
  rsync -az ./var/lib "$TARGET_HOST":~/var/
  rsync -az ./compose.yaml "$TARGET_HOST":~/

  ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" 'COMPOSE_PROGRESS=quiet docker compose up -d'

  sleep 2
  for i in 1 2 3 4 5; do
    if COMPOSE_PROGRESS=quiet docker compose -p "$DOCKER_PROJECT" -f compose.tool.yaml run --rm ch bash -c "clickhouse-client --host='$CLICKHOUSE_HOST' --user '$CLICKHOUSE_USER' --password '$CLICKHOUSE_PASSWORD' --query=\"SELECT 'OK'\"" >/dev/null 2>&1; then
      log_info 'ClickHouseへ接続確認できました(=起動済み)'
      return
    else
      log_info "ClickHouse接続試行中... (${i}/5)、${i}秒待機します"
      sleep "$i"
    fi
  done
  log_error 'ClickHouseへ接続できませんでした。手動確認お願いします'
  echo "COMPOSE_PROGRESS=quiet docker compose -p \"$DOCKER_PROJECT\" -f compose.tool.yaml run --rm ch bash -c \"clickhouse-client --host='$CLICKHOUSE_HOST' --user '$CLICKHOUSE_USER' --password '$CLICKHOUSE_PASSWORD' --query=\\\"SELECT 'OK'\\\"\""
  exit 1
}

start_timer "$@"
(($# == 1)) || (echo '引数は1つだけ必要です' >&2 && usage)
readonly TARGET_HOST="$1"
CLICKHOUSE_HOST="$(ssh -F"${SSH_CONFIG_FILE}" -G "$TARGET_HOST" | grep '^hostname' | cut -d' ' -f2)"
readonly CLICKHOUSE_HOST
readonly DOCKER_PROJECT='deploy-perf'
ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" "touch ~/.hushlogin" 2>&1 || {
  echo "ssh失敗: $TARGET_HOST"
  exit 0
}

deploy_perf_servers
log_info "Gateway($TARGET_HOST)のデプロイ完了"

end_timer "$@"
