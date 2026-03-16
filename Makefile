IMAGE_NAME ?= mperon/backupfire
VERSION_FILE := ./VERSION
VERSION = $(shell cat $(VERSION_FILE) | tr -d '\n' )
CMD ?= cron

.PHONY: build run db-up compose-run
build:
	@echo "BackupFire: Building image for version $(VERSION).."
	docker pull "$(IMAGE_NAME):latest" || true
	docker buildx build --platform linux/amd64 \
		--cache-from "$(IMAGE_NAME):latest" \
		-t "$(IMAGE_NAME):v$(VERSION)" \
		-t "$(IMAGE_NAME):latest" \
		.
	docker -D --log-level=debug push "$(IMAGE_NAME):v$(VERSION)"
	docker -D --log-level=debug push "$(IMAGE_NAME):latest"
run:
	-docker container stop pgbackup
	-docker container rm pgbackup
	-mkdir -p $(PWD)/volumes/{data,config}
	docker run --name pgbackup \
		-v "$(PWD)/volumes/data:/app/data" \
		-v "$(PWD)/volumes/config:/app/config:ro" \
		$(IMAGE_NAME):$(IMAGE_TAG) \
		$(CMD)
db-up:
	docker compose -f docker-compose-dev.yml stop postgres
	docker compose -f docker-compose-dev.yml up -d postgres

compose-run:
	docker compose -f docker-compose-dev.yml up -d pgbackup

.PHONY: run-test

run-test:
	docker compose up --build --force-recreate --no-deps --remove-orphans
