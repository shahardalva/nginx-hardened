SHELL := /bin/bash
REFERENCE_IMAGE ?= nginx:1.25-bookworm
IMAGE ?= nginx-hardened:latest
ROOT := $(abspath .)
export TMPDIR ?= $(HOME)/tmp

.PHONY: deb image test scan all clean

deb:
	rm -f dist/*.deb
	mkdir -p dist
	docker build -f build/Dockerfile -t nginx-hardened-builder build
	docker run --rm -v $(ROOT)/dist:/out nginx-hardened-builder
	@echo "built: $$(ls -1 dist/*.deb)"

image:
	docker build -f Containerfile -t $(IMAGE) .

test:
	python3 -m pytest test/ -v

scan:
	mkdir -p reports
	trivy image --pkg-types os $(IMAGE) > reports/hardened-trivy.txt 2>&1
	-grype $(IMAGE) -o table > reports/hardened-grype.txt 2>/dev/null
	@echo "scans written to reports/"

all: deb image test

clean:
	rm -rf dist
	-docker rmi $(IMAGE) nginx-hardened-builder 2>/dev/null || true
