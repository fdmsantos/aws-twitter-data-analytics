CRAWLER_NAME = $(shell terraform output -json | jq -r .glue_tweet_crawler.value)
DROP_DUPLICATES_JOB = $(shell terraform output -json | jq -r .glue_drop_duplicates_job.value)

define setup_collection_env
	$(eval ENV_FILE := 01-data-collection-app/.env)
	@echo " - setup env $(ENV_FILE)"
	$(eval include 01-data-collection-app/.env)
	$(eval export sed 's/=.*//' 01-data-collection-app/.env)
endef

run-collection:
	$(call setup_collection_env)
	cd 01-data-collection-app && go run main.go

run-drop-duplicates:
	aws glue start-job-run --job-name $(DROP_DUPLICATES_JOB)

run-crawler:
	aws glue start-crawler --name $(CRAWLER_NAME)

deploy:
	terraform init
	terraform apply

.PHONY: run-collection run-drop-duplicates run-crawler deploy