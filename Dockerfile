# --- build ---
FROM golang:1.24-bookworm AS builder
WORKDIR /src
COPY . .

# Buildx sets TARGETARCH (amd64/arm64) when building --platform
ARG TARGETARCH=amd64
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/ping-pong-app .

# sleep binary for K8s preStop (distroless has no shell)
FROM busybox:1.36.1-musl AS tools

# --- run ---
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=builder /out/ping-pong-app /app/ping-pong-app
COPY --from=tools /bin/sleep /bin/sleep
USER nonroot
EXPOSE 8080
ENTRYPOINT ["/app/ping-pong-app", "--mode=server"]
