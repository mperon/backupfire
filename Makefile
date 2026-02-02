IMAGE_NAME ?= mperon/pgbackup
IMAGE_TAG ?= v.0.0.1
CMD ?= cron

.PHONY: build run db-up compose-run
build:
	docker container stop pgbackup
	docker container rm pgbackup
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

run:
	-docker container stop pgbackup
	-docker container rm pgbackup
	-mkdir -p $(PWD)/volumes/{data,config}
	docker run --name pgbackup \
		-v "$(PWD)/volumes/data:/app/data" \
		-v "$(PWD)/volumes/config:/app/config:ro" \
		-e BK_CRON="0 2 * * *" \
		-e DB_HOST=host.docker.internal \
		-e DB_PORT=5432 \
		-e DB_USER=postgres \
		-e DB_NAME=postgres \
		-e DB_PASSWORD=postgres \
		$(IMAGE_NAME):$(IMAGE_TAG) \
		$(CMD)
db-up:
	docker compose -f docker-compose-dev.yml stop postgres
	docker compose -f docker-compose-dev.yml up -d postgres

compose-run:
	docker compose -f docker-compose-dev.yml up -d pgbackup
