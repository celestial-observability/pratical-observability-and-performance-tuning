################################################################################
# Tool
################################################################################
.PHONY: tool.check-required
tool.check-required: ## 必要なコマンドがあるか確認
	@go version
	@echo "direnv: $$(direnv --version)"
	@docker --version
	@jq --version
	@aws --version
	@aws sts get-caller-identity | jq -r '["AWS USER", .UserId] | join("=")'
