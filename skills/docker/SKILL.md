---
name: docker
tags: []
description: Docker best practices: image security, build efficiency, runtime hardening, Compose, local tooling (Colima, OrbStack). Use when writing or reviewing Dockerfiles and Compose files.
license: MIT
---

# Docker

## Image security
- Never run as root. Prefer images with built-in non-root user: distroless `nonroot`, `node` user in Node images, `nobody` in Alpine. Otherwise add non-root user and switch: `USER appuser`
- Minimal base: `distroless`, `alpine`, or official slim variants
- Pin by digest or immutable tag. Never `FROM node:latest` or `image: myapp:latest` in Compose
- Multi-stage builds: build in full image, copy only artifact to minimal runtime image
- No build tools in final image
- Scan with Trivy or Grype in CI. Fail on critical/high CVEs
- Multi-arch: build with `--platform linux/amd64,linux/arm64` for cross-platform targets

## Dockerfile
- One process per container
- Enable BuildKit: `DOCKER_BUILDKIT=1`. Use `--mount=type=cache` for dependency caches, `--mount=type=secret` for build-time secrets
- `COPY` specific files. Avoid `COPY . .` when targeted copy suffices
- Layer order: least → most frequently changed. `COPY package.json` before `COPY src/`
- `.dockerignore`: exclude `.git`, `node_modules`, test files, secrets, `.env`
- Explicit `WORKDIR`. No implicit root working dir
- `ENTRYPOINT` for executable, `CMD` for default args
- No secrets in `ENV`, `ARG`, or `RUN` — persist in layer history. Use `--mount=type=secret`
- `HEALTHCHECK` on all long-running services

## Runtime
- Read-only root filesystem where possible: `--read-only`
- Drop all capabilities, re-add only what's needed: `--cap-drop ALL --cap-add NET_BIND_SERVICE`
- No `--privileged` in production
- Set resource limits: `--memory`, `--cpus`
- Named volumes for persistent data. No bind mounts in production
- No secrets via env vars. Use Docker secrets or mounted secret files
- Log rotation: set `--log-opt max-size=10m --log-opt max-file=3`. Unbounded logs fill disks

## Compose
- `compose.yml` for local dev only. Production: Kubernetes, ECS, or equivalent
- Explicit dependencies: `depends_on` + `condition: service_healthy`
- Named volumes for persistent data. Never rely on container filesystem
- `env_file` for local config. Never commit `.env` with real secrets
- `restart: unless-stopped` for crash-resilient services
- Custom networks per service group. Avoid default bridge
- `profiles:` for optional services (e.g. debug tools, mock servers). Keep default startup lean

## Maintenance
- `docker system prune -f` regularly. Dangling images and stopped containers accumulate fast
- `docker image prune -a` to remove unused images. Run in CI after builds
- Inspect layer bloat with `dive` before pushing large images

## Local tooling
- **Colima**: `colima start --cpu 4 --memory 8 --disk 60`. Default VM is undersized
- Switch context after start: `docker context use colima`
- `colima stop` when not in use. Idle VM still consumes resources
- **OrbStack**: preferred on Apple Silicon — lower memory overhead, faster mounts
- Both are license-free alternatives to Docker Desktop for teams
- Lima/Colima: use `~/.lima/<profile>` for multiple VM profiles (e.g. `arm64`, `rosetta`)