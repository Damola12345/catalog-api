IMAGE ?= catalog-api:local

.PHONY: test lint build run scan k8s-render k8s-apply tf-check local-test local-clean

test:            ## Unit tests with race detector
	cd app && go test -race -count=1 ./...

lint:            ## Go + Dockerfile lint (needs golangci-lint, hadolint)
	cd app && golangci-lint run
	hadolint docker/Dockerfile

build:           ## Build the container image (context = repo root)
	docker build -f docker/Dockerfile --build-arg VERSION=$$(git rev-parse --short HEAD) -t $(IMAGE) .

run: build       ## Run locally on :8080 with a throwaway API key
	docker run --rm -p 8080:8080 -e API_KEY=dev-only --read-only $(IMAGE)

scan: build      ## Same gate CI applies
	trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 $(IMAGE)

k8s-render:      ## Print the fully rendered manifests
	kubectl kustomize k8s/base/

k8s-apply:       ## Server-side dry run, then apply
	kubectl apply -k k8s/base/ --dry-run=server
	kubectl apply -k k8s/base/

tf-check:        ## fmt + validate every root module
	terraform fmt -check -recursive terraform/
	for d in terraform/bootstrap terraform/live; do \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate; \
	done

local-test:      ## Deploy to a local kind cluster and run end-to-end checks
	./scripts/local-cluster-test.sh

local-clean:     ## Delete the local kind cluster
	./scripts/local-cluster-test.sh cleanup
