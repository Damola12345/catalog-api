# syntax=docker/dockerfile:1.7
# Build context is the repo root:  docker build -f docker/Dockerfile .

# build stage 

FROM golang:1.27-alpine AS build
WORKDIR /src

# Dependency layer first so it is cached independently of source changes.
COPY app/go.mod ./
RUN go mod download

COPY app/ ./

ARG VERSION=dev
# Static binary, no cgo, stripped, reproducible paths.
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/server ./cmd/server

# runtime stage 
# The :nonroot tag runs as UID/GID 65532.
FROM gcr.io/distroless/static-debian12:nonroot

ARG VERSION=dev
LABEL org.opencontainers.image.title="catalog-api" \
      org.opencontainers.image.source="https://github.com/Damola12345/catalog-api" \
      org.opencontainers.image.version="${VERSION}"

COPY --from=build --chown=65532:65532 /out/server /server

USER 65532:65532
EXPOSE 8080

ENTRYPOINT ["/server"]
