# Echo Pong — Deployment Guide

Production-ready packaging, CI/CD, and Kubernetes deployment for the ping-pong Go service.

---

## Architecture overview

```
Developer push / tag
        │
        ▼
 GitHub Actions ──► Trivy (block CRITICAL/HIGH)
        │
        ├──► GHCR multi-arch image (amd64 + arm64)
        └──► GitHub Release binaries (linux/darwin/windows × amd64/arm64)
                │
                ▼
        Kubernetes (Kind / Minikube / EKS)
                │
        Ingress ──► ClusterIP Service ──► Pods (non-root, secret file mount)
```

---

## Prerequisites

- Docker (with Buildx)
- Kind **or** Minikube
- kubectl
- Go 1.24 (local binary builds)
- GitHub account (for GHCR + Actions)

---

## 1. Container image

### Build locally

```bash
# Create a secret file for local runs
echo "local-dev-token" > /tmp/pingpong-token

docker build -t ping-pong:local .

docker run --rm \
  -p 8080:8080 \
  -e PORT=8080 \
  -e SECRET_FILE_PATH=/secrets/token \
  -v /tmp/pingpong-token:/secrets/token:ro \
  ping-pong:local
```

Wait ~10 seconds for the intentional startup delay, then:

```bash
curl http://localhost:8080/health
curl -H "Authorization: local-dev-token" http://localhost:8080/ping
```

### Security properties of the image

| Control | How |
|---------|-----|
| Non-root | Distroless `nonroot` user (UID 65532) |
| Minimal surface | Multi-stage + `gcr.io/distroless/static-debian12` |
| No secrets in image | Secret mounted at runtime only |
| Read-only FS | Enforced in Kubernetes `securityContext` |

---

## 2. Kubernetes (local)

### Replace the image placeholder

Edit `k8s/deployment.yaml` and set:

```yaml
image: ghcr.io/<your-github-user-or-org>/echo-pong:<tag>
```

For a pure local demo without GHCR, build and load into the cluster:

```bash
# Kind
kind create cluster --name ping-pong
docker build -t ping-pong:local .
kind load docker-image ping-pong:local --name ping-pong
# set image: ping-pong:local and imagePullPolicy: Never|IfNotPresent

# Minikube
minikube start
eval $(minikube docker-env)   # bash; on PowerShell use minikube docker-env | Invoke-Expression
docker build -t ping-pong:local .
```

### Create the secret

```bash
kubectl apply -f k8s/namespace.yaml

kubectl create secret generic ping-pong-secret \
  --namespace=ping-pong \
  --from-literal=token='local-dev-token' \
  --dry-run=client -o yaml | kubectl apply -f -

# Or, for a disposable local demo only, edit k8s/secret.yaml (CHANGE_ME) and apply it.
```

### Enable Ingress

```bash
# Minikube
minikube addons enable ingress

# Kind — install ingress-nginx (see https://kind.sigs.k8s.io/docs/user/ingress/)
```

### Apply manifests

```bash
kubectl apply -f k8s/namespace.yaml
# secret created above
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
kubectl apply -f k8s/networkpolicy.yaml

kubectl rollout status deployment/ping-pong -n ping-pong
```

### Access the app

```bash
# Port-forward (works without Ingress)
kubectl -n ping-pong port-forward svc/ping-pong 8080:80

curl http://localhost:8080/health
curl -H "Authorization: local-dev-token" http://localhost:8080/ping

# Via Ingress (after mapping ping-pong.local to the Ingress IP)
curl -H "Host: ping-pong.local" http://<INGRESS_IP>/health
```

### Why probes look the way they do

The process sleeps **10 seconds** before calling `ListenAndServe`. During that window the container is running but nothing answers HTTP.

- **startupProbe** — retries `/health` for up to ~40s so the pod is not killed during boot.
- **readinessProbe** — only Ready pods receive Service traffic; during rolling updates old pods keep serving.
- **livenessProbe** — starts after startup succeeds; restarts truly stuck processes.
- **preStop + `/bin/sleep 5`** — after the pod is marked not-Ready, wait briefly so kube-proxy/endpoint updates propagate before SIGTERM (avoids in-flight connection resets). Distroless has no shell, so a static `sleep` is copied into the image.

Without a startup probe (or a long readiness delay), liveness failures during the sleep cause crash loops and break zero-downtime.

---

## 3. Deployment strategy (zero downtime)

Configured in `k8s/deployment.yaml`:

- `replicas: 2`
- `RollingUpdate` with `maxUnavailable: 0`, `maxSurge: 1`
- Readiness gated on `/health`

Upgrade flow:

1. New pod starts, sleeps 10s, then passes startup + readiness.
2. Only then is it added to Service endpoints.
3. An old pod is terminated.
4. At least one Ready pod always serves traffic.

---

## 4. Scaling strategy

| Layer | Approach |
|-------|----------|
| Horizontal | Increase `replicas`, or add an HPA on CPU / custom RPS metrics |
| Vertical | Small requests/limits (static Go binary is tiny); raise only if needed |
| Cluster | Multi-AZ node groups; Karpenter / Cluster Autoscaler on EKS |
| Global | Separate regional clusters + latency-based DNS (Route 53) |

ARM64 is preferred via `preferredDuringSchedulingIgnoredDuringExecution` so Graviton nodes are chosen when present, without failing on amd64-only Kind/Minikube.

---

## 5. Security measures

1. **Containers never run as root** — UID 65532 in image and pod `securityContext`.
2. **Read-only root filesystem** + drop all capabilities + no privilege escalation.
3. **Secrets as files** — `SECRET_FILE_PATH` mounts a K8s Secret; token is not an env var and not in git.
4. **Trivy gate** — release workflow fails on CRITICAL/HIGH before pushing production tags.
5. **NetworkPolicy** — ingress only from ingress-nginx / same namespace; egress limited to DNS (no general internet).
6. **ClusterIP + Ingress** — pods are not exposed via NodePort/LoadBalancer as the primary path.
7. **Distroless runtime** — no shell in the production image.

---

## 6. CI/CD pipeline

### Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `.github/workflows/ci.yml` | PR / push | `go build` + `go vet` |
| `.github/workflows/release.yml` | push to main, tags `v*.*.*`, manual | Trivy → multi-arch GHCR → binaries + GitHub Release |

### Release pipeline steps

1. Build amd64 image locally on the runner.
2. **Trivy** scan with `severity: CRITICAL,HIGH` and `exit-code: 1` — blocks the rest on findings.
3. Buildx push `linux/amd64,linux/arm64` to `ghcr.io/<owner>/<repo>`.
4. On `vX.Y.Z` tags: cross-compile binaries, attach to a GitHub Release.

### Permissions

- `packages: write` — push to GHCR with `GITHUB_TOKEN`
- `contents: write` — create Releases

After the first package push, make the GHCR package public (or grant pull to the cluster identity) so nodes can pull.

---

## 7. Multi-architecture builds

`docker buildx` builds each platform and publishes a **manifest list** under one tag. Clients pull that tag; the runtime selects amd64 or arm64 automatically.

On GitHub-hosted (amd64) runners, arm64 is built via QEMU (`docker/setup-qemu-action`). For faster arm64 builds in production CI, add a native ARM runner.

Dockerfile uses `TARGETARCH` so Buildx injects the correct GOOS/GOARCH at build time.

---

## 8. Versioning and tagging

| Tag | When | Use |
|-----|------|-----|
| `sha-<short>` | Every main push | Traceable CI builds |
| `vX.Y.Z` | Semver git tag | Immutable release |
| `vX.Y` | Semver git tag | Floating minor pointer |
| `latest` | Semver git tag only | Convenience; **avoid in production Deployments** |

**Production recommendation:** pin the Deployment to a digest:

```yaml
image: ghcr.io/owner/echo-pong@sha256:...
```

### Managing older / stale versions

- Keep semver tags (`vX.Y.Z`) for supported releases.
- Delete or expire **untagged** digests (GHCR package settings or cleanup Action).
- On ECR: lifecycle policy — e.g. keep last 20 tagged images; expire untagged after 14 days.
- Retire major versions in docs; remove old GitHub Release assets when support ends.
- Never rely on floating `latest` for prod rollouts.

---

## 9. Going cloud: Amazon EKS

Same manifests; change registry, ingress class, and secret sourcing.

1. **Cluster** — EKS in private subnets; public API optional; nodes preferably Graviton (ARM64).
2. **Registry** — push/mirror to **ECR**; grant pull via IRSA or node role. VPC endpoints for ECR so pulls stay private.
3. **Ingress** — AWS Load Balancer Controller (ALB) or NLB; map to the ClusterIP Service.
4. **Secrets** — AWS Secrets Manager + External Secrets Operator → same file mount path (`/var/run/secrets/pingpong/token`).
5. **Deploy** — `kubectl apply` / Helm / Argo CD; rolling strategy unchanged.
6. **Observability** — CloudWatch Container Insights or Prometheus; alert on probe failures and 5xx from ALB.

Example high-level flow:

```
GitHub Actions ──push──► ECR (multi-arch)
                           │
                     EKS nodes (IRSA pull)
                           │
              ALB Ingress ──► Service ──► Pods
```

---

## 10. Fast global image pulls (AWS)

Teams and clusters worldwide need low-latency pulls:

1. **ECR replication** — replicate the repository to regions near each cluster/team.
2. **VPC endpoints** (`ecr.api`, `ecr.dkr`, S3) — pulls do not traverse the public internet.
3. **Pull-through cache** — cache upstream (e.g. GHCR) into regional ECR.
4. **CI once, replicate many** — pipeline pushes to a primary region; replication fans out asynchronously.

CloudFront in front of OCI registries is uncommon; regional ECR replicas + private networking is the usual AWS answer.

---

## Deliverables checklist

- [x] `Dockerfile` — multi-stage, non-root, distroless
- [x] `k8s/` — namespace, secret template, deployment, service, ingress, networkpolicy
- [x] `.github/workflows/` — CI + release (scan, GHCR, binaries)
- [x] This document — approach and cloud strategy
