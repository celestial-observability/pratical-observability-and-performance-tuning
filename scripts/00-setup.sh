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
  - 引数(target_host)に対してsetupする
実行方法:
  - $0 <target_host>
実行例:
  - $0 web
EOF
  exit 2
}

# Set up apt pkg
setup_apt() {
  ssh -F "$SSH_CONFIG_FILE" -o BatchMode=yes "$TARGET_HOST" <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

sudo -n apt-get -qq update
sudo -n apt-get -qq install -y tree ca-certificates curl

EOF
}

# Set up mysqldef
# ref: https://github.com/sqldef/sqldef/releases
# https://github.com/sqldef/sqldef/releases/download/v3.8.14/mysqldef_linux_amd64.tar.gz
setup_mysqldef() {
  ssh -F "$SSH_CONFIG_FILE" -o BatchMode=yes "$TARGET_HOST" <<'EOF'
set -euo pipefail

mysqldef_version='3.9.7'
curl -fsSL -o mysqldef_linux.tar.gz https://github.com/sqldef/sqldef/releases/download/v${mysqldef_version}/mysqldef_linux_$(dpkg --print-architecture).tar.gz
tar -xzf mysqldef_linux.tar.gz
sudo -n mv mysqldef /usr/local/bin/mysqldef
sudo -n chmod a+x /usr/local/bin/mysqldef
rm mysqldef_linux.tar.gz

echo "mysqldef $(mysqldef --version)"
EOF
}

# Set up Docker's apt repository.
# ref: https://docs.docker.com/engine/install/ubuntu/
# 何度実行してもOK
setup_docker() {
  ssh -F "$SSH_CONFIG_FILE" -o BatchMode=yes "$TARGET_HOST" <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

sudo -n apt-get -qq update
sudo -n apt-get -qq install -y ca-certificates curl
sudo -n install -m 0755 -d /etc/apt/keyrings
sudo -n curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo -n chmod a+r /etc/apt/keyrings/docker.asc

sudo -n tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOT
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOT

sudo -n apt-get -qq update
sudo -n apt-get -qq install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo -n usermod -aG docker isucon
docker -v
EOF
}

# Set up OpenTelemetry Collector Contrib distribution
# ref: https://github.com/open-telemetry/opentelemetry-collector-contrib
# 実際にdebなどを配布しているリポジトリは別(専用のリポジトリがある)
# 何度実行してもOK
setup_otelcol_contrib() {
  ssh -F "$SSH_CONFIG_FILE" -o BatchMode=yes "$TARGET_HOST" <<'EOF'
set -euo pipefail

curl -fsSLO https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.142.0/otelcol-contrib_0.142.0_linux_$(dpkg --print-architecture).deb
sudo -n apt-get install -qq ./otelcol-contrib_0.142.0_linux_$(dpkg --print-architecture).deb

/usr/bin/otelcol-contrib --version
EOF
}

start_timer "$@"
(($# == 1)) || (echo '引数は1つだけ必要です' >&2 && usage)
readonly TARGET_HOST="$1"
ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" "touch ~/.hushlogin" 2>&1 || {
  echo "ssh失敗: $TARGET_HOST"
  exit 0
}

setup_apt
setup_mysqldef
setup_docker
setup_otelcol_contrib

end_timer "$@"
