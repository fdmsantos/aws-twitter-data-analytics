CRAWLER_NAME = $(shell terraform output -json | jq -r .glue_tweet_crawler.value)
DROP_DUPLICATES_JOB = $(shell terraform output -json | jq -r .glue_drop_duplicates_job.value)
GLUE_WORKFLOW = $(shell terraform output -json | jq -r .glue_workflow.value)
EMR_PUBLIC_DNS = $(shell terraform output -json | jq -r .emr_public_dns.value)
STATE_MACHINE_ARN = $(shell terraform output -json | jq -r .state_machine_arn.value)

define setup_collection_env
	$(eval ENV_FILE := 01-data-collection-app/.env)
	@echo " - setup env $(ENV_FILE)"
	$(eval include 01-data-collection-app/.env)
	$(eval export sed 's/=.*//' 01-data-collection-app/.env)
endef

run-collection:
	$(call setup_collection_env)
	cd 01-data-collection-app && go run main.go

run-glue-workflow:
	aws glue start-workflow-run --name $(GLUE_WORKFLOW)

run-drop-duplicates:
	aws glue start-job-run --job-name $(DROP_DUPLICATES_JOB)

run-crawler:
	aws glue start-crawler --name $(CRAWLER_NAME)

run-step-function:
	aws stepfunctions start-execution --state-machine-arn $(STATE_MACHINE_ARN) --input "{\"Year\" : \"$(STATE_MACHINE_RUN_YEAR)\", \"Month\" : \"$(STATE_MACHINE_RUN_MONTH)\", \"Day\" : \"$(STATE_MACHINE_RUN_DAY)\"}"

ssh-emr:
	ssh -i $(EMR_KEY) hadoop@$(EMR_PUBLIC_DNS)

deploy:
	terraform init
	terraform apply

destroy:
	terraform destroy

.PHONY: run-collection run-glue-workflow run-drop-duplicates run-crawler deploy destroy ssh-emr