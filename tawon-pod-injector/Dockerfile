# syntax=docker/dockerfile:1.7
#
# Multi-stage build for tawon-pod-injector.
# Final image is distroless static-debian12:nonroot — ~15 MB.

ARG GO_VERSION=1.25
ARG DISTROLESS_TAG=nonroot

FROM golang:${GO_VERSION}-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build \
        -trimpath \
        -ldflags="-s -w -buildid= -X main.version=${VERSION}" \
        -o /out/injector \
        ./cmd/injector

FROM gcr.io/distroless/static-debian12:${DISTROLESS_TAG}
COPY --from=build /out/injector /injector
EXPOSE 8443
ENTRYPOINT ["/injector"]
