################################################################################
# デプロイ
################################################################################
.PHONY: perf.deploy
perf.deploy: ## パフォーマンス計測環境をデプロイ
	@if docker compose exec clickhouse echo 'true' 2>/dev/null; then \
		echo "パフォーマンス計測環境はローカルにデプロイされています"; \
	else \
		scripts/05-deploy-perf-gateway.sh web; \
	fi

################################################################################
# ブラウザで開く
# ################################################################################
.PHONY: perf.open
perf.open: ## Grafana/ClickHouseをブラウザで開く
	$(eval TARGET_HOST=localhost)
	@open "http://$(TARGET_HOST):8123/play?user=${CLICKHOUSE_USER}&password=${CLICKHOUSE_PASSWORD}"
	@open "http://$(TARGET_HOST):3000/dashboards"

.PHONY: perf.open-ch
perf.open-ch: ## ClickHouseのWebUIをブラウザで開く
	$(eval TARGET_HOST=localhost)
	@open "http://$(TARGET_HOST):8123/play?user=${CLICKHOUSE_USER}&password=${CLICKHOUSE_PASSWORD}"

.PHONY: perf.open-grafana
perf.open-grafana: ## Grafanaをブラウザで開く
	$(eval TARGET_HOST=localhost)
	@open "http://$(TARGET_HOST):3000/dashboards"
