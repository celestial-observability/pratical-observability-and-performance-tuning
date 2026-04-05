################################################################################
# 一覧
################################################################################
.PHONY: aws.status
aws.status: ## AWSのインスタンス状態とCFnスタック一覧
	@aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query 'StackSummaries[].{Name:StackName,Created:CreationTime}' --output table
	@aws ec2 describe-instances --filters 'Name=tag:Name,Values=web,bench' --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,State:State.Name,PublicIp:PublicIpAddress,InstanceId:InstanceId}' --output table

################################################################################
# CFnスタック作成
################################################################################
.PHONY: aws.create-cfn
aws.create-cfn: validate-ssh-private-key ## AWSのCFnスタックを作成
	$(eval MY_IP := $(shell curl -fsS https://checkip.amazonaws.com))
	@aws cloudformation create-stack --stack-name $(STACK_NAME) --template-body file://private-isu.yaml --parameters \
		ParameterKey=GitHubUsername,ParameterValue="${GITHUB_USERNAME}" \
		ParameterKey=MyIp,ParameterValue=$(MY_IP)
	@echo "$(STACK_NAME): 作成中です(約1分かかります)"
	@time aws cloudformation wait stack-create-complete --stack-name $(STACK_NAME)

################################################################################
# 停止
################################################################################
.PHONY: aws.down
aws.down: ## AWSのインスタンスを停止
	@make aws.down-web
	@make aws.down-bench

.PHONY: aws.down-web
aws.down-web: ## webインスタンスを停止
	$(eval STACK_ID := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].StackId' --output text))
	$(eval WEB_INSTANCE_ID := $(shell aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values=$(STACK_ID)" 'Name=tag:Name,Values=web' --query 'Reservations[].Instances[].InstanceId' --output text))
	@aws ec2 stop-instances --instance-ids $(WEB_INSTANCE_ID)

.PHONY: aws.down-bench
aws.down-bench: ## benchインスタンスを停止
	$(eval STACK_ID := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].StackId' --output text))
	$(eval BENCH_INSTANCE_ID := $(shell aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values=$(STACK_ID)" 'Name=tag:Name,Values=bench' --query 'Reservations[].Instances[].InstanceId' --output text))
	@aws ec2 stop-instances --instance-ids $(BENCH_INSTANCE_ID)

################################################################################
# 起動
################################################################################
.PHONY: aws.up
aws.up: ## AWSのインスタンスを起動
	@make aws.up-web
	@make aws.up-bench

.PHONY: aws.up-web
aws.up-web: ## webインスタンスを起動
	$(eval STACK_ID := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].StackId' --output text))
	$(eval WEB_INSTANCE_ID := $(shell aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values=$(STACK_ID)" 'Name=tag:Name,Values=web' --query 'Reservations[].Instances[].InstanceId' --output text))
	@aws ec2 start-instances --instance-ids $(WEB_INSTANCE_ID)
	@aws ec2 wait instance-running --instance-ids $(WEB_INSTANCE_ID)
	@make aws.add-myip-inbound-rule

.PHONY: aws.up-bench
aws.up-bench: ## benchインスタンスを起動
	$(eval STACK_ID := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].StackId' --output text))
	$(eval BENCH_INSTANCE_ID := $(shell aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values=$(STACK_ID)" 'Name=tag:Name,Values=bench' --query 'Reservations[].Instances[].InstanceId' --output text))
	@aws ec2 start-instances --instance-ids $(BENCH_INSTANCE_ID)
	@aws ec2 wait instance-running --instance-ids $(BENCH_INSTANCE_ID)
	@make aws.add-myip-inbound-rule

################################################################################
# MY_IPの追加と掃除
################################################################################
.PHONY: aws.add-myip-inbound-rule
aws.add-myip-inbound-rule: ## AWSのSecurityGroupのMY_IP関連のインバウンドルールを追加
	$(eval SG_ID := $(shell aws ec2 describe-security-groups --filters "Name=tag:aws:cloudformation:stack-name,Values=$(STACK_NAME)" --query 'SecurityGroups[0].GroupId' --output text))
	$(eval MY_IP := $(shell curl -fsS https://checkip.amazonaws.com))
	@if aws ec2 describe-security-groups --group-ids "$(SG_ID)" --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text | grep -q "$(MY_IP)/32"; then \
		echo "MY_IP許可済み: $(MY_IP)/32"; \
	else \
		aws ec2 authorize-security-group-ingress --group-id "$(SG_ID)" --ip-permissions '[{"IpProtocol": "-1", "IpRanges": [{"CidrIp": "$(MY_IP)/32"}]}]'; \
	fi
	@ssh web   -F "${SSH_CONFIG_FILE}" 'echo "ssh web:   OK"' || echo 'ssh web:   SSH NG'
	@ssh bench -F "${SSH_CONFIG_FILE}" 'echo "ssh bench: OK"' || echo 'ssh bench: SSH NG'

.PHONY: aws.clean-and-add-myip-inbound-rule
aws.clean-and-add-myip-inbound-rule: ## AWSのSecurityGroupのMY_IP関連のインバウンドルールを全削除して、追加
	$(eval SG_ID := $(shell aws ec2 describe-security-groups --filters "Name=tag:aws:cloudformation:stack-name,Values=$(STACK_NAME)" --query 'SecurityGroups[0].GroupId' --output text))
	@for cidr in $(shell aws ec2 describe-security-groups --group-ids $(SG_ID) --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output json | jq -r '.[] | select(endswith("/32"))'); do \
		aws ec2 revoke-security-group-ingress --group-id $(SG_ID) --ip-permissions '[{"IpProtocol": "-1", "IpRanges": [{"CidrIp": "'$$cidr'"}]}]'; \
	done
	@make aws.add-myip-inbound-rule

################################################################################
# SSHの設定
################################################################################
.PHONY: aws.setup-ssh-config
aws.setup-ssh-config: validate-ssh-private-key ## SSH設定をセットアップ
	$(eval STACK_ID := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].StackId' --output text))
	$(eval WEB_HOST_IP := $(shell aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values=$(STACK_ID)" 'Name=tag:Name,Values=web' --query 'Reservations[0].Instances[0].PublicIpAddress' --output text))
	$(eval BENCH_HOST_IP := $(shell aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values=$(STACK_ID)" 'Name=tag:Name,Values=bench' --query 'Reservations[0].Instances[0].PublicIpAddress' --output text))
	@mkdir -p .ssh
	@sed \
		-e "s|{{SSH_PRIVATE_KEY_PATH}}|${SSH_PRIVATE_KEY_PATH}|g" \
		-e "s|{{WEB_HOST_IP}}|$(WEB_HOST_IP)|g" \
		-e "s|{{BENCH_HOST_IP}}|$(BENCH_HOST_IP)|g" \
		.ssh/ssh_config.tmpl > .ssh/config
	@ssh web   -F "${SSH_CONFIG_FILE}" 'echo "ssh web:   OK"' || echo 'ssh web:   SSH NG'
	@ssh bench -F "${SSH_CONFIG_FILE}" 'echo "ssh bench: OK"' || echo 'ssh bench: SSH NG'

# SSH秘密鍵の検証
# SSH_PRIVATE_KEY_PATHが指す秘密鍵の公開鍵がGitHubアカウントに登録されているか確認
# 理由: EC2に登録する公開鍵は https://github.com/${GITHUB_USERNAME}.keys を利用しているため
# GITHUB_USERNAMEは.envrc.overrideに記載
validate-ssh-private-key:
	$(eval PUBLIC_KEY := $(shell ssh-keygen -y -f ${SSH_PRIVATE_KEY_PATH} | cut -d ' ' -f1,2))
	@test -n "$${GITHUB_USERNAME:-}" || { \
		echo '----[ERROR]----' >&2; \
		echo 'GITHUB_USERNAMEが設定されていません' >&2; \
		echo 'cp .envrc.override.sample .envrc.overrideを実施し、' >&2; \
		echo 'GitHubアカウント名(GITHUB_USERNAME)を.envrc.overrideに設定してdirenv allowをしてください' >&2; \
		exit 1; \
	}
	@curl -fsS "https://github.com/${GITHUB_USERNAME}.keys" | grep -q "$(PUBLIC_KEY)" || ( \
		echo '----[ERROR]----' >&2; \
		echo "秘密鍵=${SSH_PRIVATE_KEY_PATH} に対応する公開鍵が https://github.com/${GITHUB_USERNAME}.keys にありません" >&2; \
		echo '登録済みの公開鍵に対応する秘密鍵のパスを.envrc.overrideに設定してください' >&2; \
		echo 'もしくはGitHubアカウント名(GITHUB_USERNAME)を.envrc.overrideに設定してください' >&2; \
		exit 1)
