SHELL := /bin/bash
REFERENCE_IMAGE ?= nginx:1.25-bookworm
IMAGE ?= nginx-hardened:latest
ROOT := $(abspath .)

.PHONY: deb
deb:
	mkdir -p dist
	docker build -f build/Dockerfile -t nginx-hardened-builder build
	docker run --rm -v $(ROOT)/dist:/out nginx-hardened-builder
	@echo "built: $$(ls -1 dist/*.deb)"

.PHONY: clean
clean:
	rm -rf dist
	-docker rmi $(IMAGE) nginx-hardened-builder 2>/dev/null || true
