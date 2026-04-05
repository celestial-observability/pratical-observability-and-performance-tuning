include makefiles/tool.mk
include makefiles/aws.mk
include makefiles/ssh.mk
include makefiles/perf.mk

################################################################################
# Main
################################################################################
.PHONY: setup
setup: ## ツール群をインストール
	@scripts/00-setup.sh web

.PHONY: deploy
deploy: ## デプロイ
	@scripts/01-deploy-app.sh web
	@scripts/01-deploy-nginx.sh web
	@scripts/01-deploy-mysql.sh web

.PHONY: analyze
analyze: ## 分析
	@scripts/03-analyze.sh
	@bash -c ' \
	scripts/04-store-nginx-access-runs.sh host.docker.internal & \
	scripts/04-store-results.sh host.docker.internal & \
	wait;'

.PHONY: bench
bench: ## ベンチマークの実行
	@scripts/02-log-rotate.sh web
	@scripts/02-bench.sh
	@scripts/02-prepare-analyze.sh web $$(jq -r '.score' tmp/result.json)

################################################################################
# Utility-Command help
################################################################################
.DEFAULT_GOAL := help

################################################################################
# マクロ
################################################################################
# Makefileの中身を抽出してhelpとして1行で出す
# $(1): Makefile名
# 使い方例: $(call help,{included-makefile})
define help
grep -E '^[\.a-zA-Z0-9_-]+:.*?## .*$$' $(1) \
| grep --invert-match "## non-help" \
| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
endef

################################################################################
# help ターゲット
################################################################################
.PHONY: help
help: ## Make ターゲット一覧
	@echo '######################################################################'
	@echo '# Makeターゲット一覧'
	@echo '# $$ make XXX'
	@echo '# or'
	@echo '# $$ make XXX --dry-run'
	@echo '######################################################################'
	@echo $(MAKEFILE_LIST) \
	| tr ' ' '\n' \
	| xargs -I {included-makefile} $(call help,{included-makefile})
