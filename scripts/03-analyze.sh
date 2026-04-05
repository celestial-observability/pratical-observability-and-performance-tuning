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
  - スロークエリ分析をする
実行方法:
  - $0
実行例:
  - $0
EOF
  exit 2
}

# Nginxアクセスログ分析(alpは直接TSV出力可能)
analyze_nginx_access_log() {
  local target_score_dir=$1
  local input_access_log="$target_score_dir/var/log/nginx/access.log"

  COMPOSE_PROGRESS=quiet docker compose -p "$DOCKER_PROJECT" -f compose.tool.yaml run --rm alp alp ltsv --config alp.yaml --file "$input_access_log" > "$target_score_dir/analyzed_nginx_access.tsv"
}

start_timer "$@"
(($# == 0)) || (echo '引数の数は0である必要があります' >&2 && usage)
readonly DOCKER_PROJECT='analyze'

# 分析
for line in results/*; do
  analyze_nginx_access_log "$line"
done

end_timer "$@"
