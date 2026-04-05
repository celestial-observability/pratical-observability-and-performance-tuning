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
  - ログの洗い替え
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
ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" "touch ~/.hushlogin" 2>&1 || {
  echo "ssh失敗: $TARGET_HOST"
  exit 0
}

# ダミーのNginxのアクセスログ
rsync -az ./dummy-nginx-access.log.tmpl "$TARGET_HOST":~/dummy-nginx-access.log.tmpl &&
  ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" '
set -euo pipefail

echo "$(AZ=Asia/Tokyo date -Iseconds) START: dummy-nginx-access.log"

sed \
  -e "s|{{START_TIME_TZ}}|$(date +"%d/%b/%Y:%H:%M:%S %z")|" \
  ~/dummy-nginx-access.log.tmpl > ~/dummy-nginx-access.log

echo "$(AZ=Asia/Tokyo date -Iseconds) END: dummy-nginx-access.log"
' &

# ダミーのMySQLのスロークエリログ
rsync -az ./dummy-mysql-slow.log.tmpl "$TARGET_HOST":~/dummy-mysql-slow.log.tmpl &&
  ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" '
set -euo pipefail

echo "$(AZ=Asia/Tokyo date -Iseconds) START: dummy-mysql-slow.log"

sed \
  -e "s/{{START_TIME_UTC}}/$(date -u +"%Y-%m-%dT%H:%M:%S.%6NZ")/" \
  -e "s/{{END_TIME_UTC}}/$(date   -u +"%Y-%m-%dT%H:%M:%S.%6NZ" -d "+80 seconds")/" \
  -e "s/{{START_UNIX_TIME_STAMP}}/$(date -u +%s)/" \
  -e "s/{{END_UNIX_TIME_STAMP}}/$(date   -u +%s -d "+70 seconds")/" \
  ~/dummy-mysql-slow.log.tmpl > ~/dummy-mysql-slow.log

echo "$(AZ=Asia/Tokyo date -Iseconds) END: dummy-mysql-slow.log"
' &

# ログ洗い替えと再起動(Nginx)
ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" '
set -euo pipefail

echo "$(AZ=Asia/Tokyo date -Iseconds) START: nginx log rotate and restart"
sudo -n chmod 777 /var/log/nginx
sudo -n chmod 666 -R /var/log/nginx/*
touch /var/log/nginx/{error,access}.log
mv /var/log/nginx/access.log{,.old}
mv /var/log/nginx/error.log{,.old}
sudo -n chown root:adm -R /var/log/nginx/
sudo -n systemctl restart nginx
sudo -n chmod 777 -R /var/log/nginx
sudo -n chmod 666 -R /var/log/nginx/*
echo "$(AZ=Asia/Tokyo date -Iseconds) END: nginx log rotate and restart"
' &

# ログ洗い替えと再起動(MySQL)
ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" '
set -euo pipefail

echo "$(AZ=Asia/Tokyo date -Iseconds) START: mysql log rotate and restart"
sudo -n chmod 777 /var/log/mysql
sudo -n chmod 666 -R /var/log/mysql/*
touch /var/log/mysql/{error,mysql-slow}.log
mv /var/log/mysql/error.log{,.old}
mv /var/log/mysql/mysql-slow.log{,.old}
sudo -n chown mysql:adm -R /var/log/mysql/
sudo -n systemctl restart mysql
sudo -n chmod 777 -R /var/log/mysql
sudo -n chmod 666 -R /var/log/mysql/*
echo "$(AZ=Asia/Tokyo date -Iseconds) END: mysql log rotate and restart"
' &

wait

end_timer "$@"
