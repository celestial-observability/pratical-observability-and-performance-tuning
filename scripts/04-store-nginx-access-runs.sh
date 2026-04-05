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
  - 引数(target_host)に対して分析結果を保存する
実行方法:
  - $0 <target_host>
実行例:
  - $0 host.docker.internal
EOF
  exit 2
}

# 分析結果を保存
store() {
  local target_score_dir=$1
  local input_result_json="$target_score_dir/result.json"
  local input_analyzed_nginx_access_run_tsv="$target_score_dir/analyzed_nginx_access.tsv"

  # 入力ファイルの有無を確認
  if [[ ! -f "$input_result_json" || ! -f "$input_analyzed_nginx_access_run_tsv" ]]; then
    log_error "入力用のファイルが存在しません: $input_result_json or $input_analyzed_nginx_access_run_tsv"
    err
  fi
  # TSVの行数が0行なら何もしない(ログフォーマットが合ってなくてalpがうまく分析できなかった)
  if [[ $(wc -l <"$input_analyzed_nginx_access_run_tsv") -eq 0 ]]; then
    log_info "tsvの行数が0行(log formatがalpと不適合): $input_analyzed_nginx_access_run_tsv"
    return
  fi

  local started_at
  started_at=$(jq -r '.started_at' "$input_result_json")
  # 既にINSERT済みなら何もしない
  local duplicated_started_at_count
  duplicated_started_at_count=$(COMPOSE_PROGRESS=quiet docker compose -p "$DOCKER_PROJECT" -f compose.tool.yaml run --rm ch clickhouse-client --host="$TARGET_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query="
    SELECT COUNT(1)
    FROM default.nginx_access_runs
    WHERE slow_run_started_at = parseDateTimeBestEffort('$started_at');
  ")
  if [[ "$duplicated_started_at_count" -gt 0 ]]; then
    return
  fi

  before_nginx_access_runs_count=$(COMPOSE_PROGRESS=quiet docker compose -p "$DOCKER_PROJECT" -f compose.tool.yaml run --rm ch clickhouse-client --host="$TARGET_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query="SELECT COUNT(1) FROM default.nginx_access_runs;")

  # 保存処理
  COMPOSE_PROGRESS=quiet docker compose -p "$DOCKER_PROJECT" -f compose.tool.yaml run --rm -T ch clickhouse-client --host "$TARGET_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query="
INSERT INTO nginx_access_runs
SELECT
  parseDateTimeBestEffort('$started_at') AS slow_run_started_at,
  *
FROM input('
  count UInt64,
  c_1xx UInt64,
  c_2xx UInt64,
  c_3xx UInt64,
  c_4xx UInt64,
  c_5xx UInt64,
  method LowCardinality(String),
  uri String,
  min Float64,
  max Float64,
  sum Float64,
  avg Float64,
  p90 Float64,
  p95 Float64,
  p99 Float64,
  stddev Float64,
  min_body Float64,
  max_body Float64,
  sum_body Float64,
  avg_body Float64
')
FORMAT TSV
" <"$input_analyzed_nginx_access_run_tsv";

  after_nginx_access_runs_count=$(COMPOSE_PROGRESS=quiet docker compose -p "$DOCKER_PROJECT" -f compose.tool.yaml run --rm ch clickhouse-client --host="$TARGET_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query="SELECT COUNT(1) FROM default.nginx_access_runs;")
  log_info "保存完了($target_score_dir): nginx_access_runs: $before_nginx_access_runs_count → $after_nginx_access_runs_count 行"
}

start_timer "$@"
(($# == 1)) || (echo '引数は1つだけ必要です' >&2 && usage)
readonly TARGET_HOST="$1"
readonly DOCKER_PROJECT='store-nginx-access-runs'
if ! COMPOSE_PROGRESS=quiet docker compose -p "$DOCKER_PROJECT" -f compose.tool.yaml run --rm ch bash -c "clickhouse-client --host='$TARGET_HOST' --user '$CLICKHOUSE_USER' --password '$CLICKHOUSE_PASSWORD' --query=\"SELECT 'OK'\"" >/dev/null 2>&1; then
  log_error "Error: ClickHouse($TARGET_HOST:9000)に接続できません in $0"
  exit 1
fi

for line in results/*; do
  store "$line"
done

nginx_access_runs_count=$(COMPOSE_PROGRESS=quiet docker compose -p "$DOCKER_PROJECT" -f compose.tool.yaml run --rm ch clickhouse-client --host="$TARGET_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query="SELECT COUNT(1) FROM default.nginx_access_runs;")
log_info "現在のテーブル: nginx_access_runs=$nginx_access_runs_count 行"

end_timer "$@"
