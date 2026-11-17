.PHONY: build test run db-up db-down docker-build

build:
	swift build

test:
	swift test

run:
	swift run Run serve

db-up:
	docker compose --profile postgres up -d db

db-down:
	docker compose --profile postgres down

docker-build:
	docker compose build app
