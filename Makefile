IMAGE_NAME ?= mperon/backupfire
IMAGE_TAG ?= 2.0.1
CMD ?= cron

.PHONY: build run db-up compose-run
build:
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

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
