# Simple Go Server - CI Pipeline

A simple Golang web server with an automated CI pipeline designed for enterprise constraints.

## Overview

| Item | Description |
|------|-------------|
| **Application** | Health-check endpoint at `/health` returning `200 OK` |
| **CI Platform** | GitHub Actions |
| **Infrastructure** | 5 Build Servers (each running 3+ concurrent jobs) |
| **Architecture** | Reusable workflows for microservices scalability |

---

## CI Pipeline Architecture

### Pipeline Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│  REPOSITORY CONFIGURATION                                            │
│  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────────┐    │
│  │ Branch          │  │ Webhooks        │  │ Runners          │    │
│  │ Protection      │  │ • Push events   │  │ • Self-hosted    │    │
│  │ • main: PR req. │  │ • PR events     │  │   (linux label)  │    │
│  │ • Status checks │  │                 │  │ • 5 servers      │    │
│  └─────────────────┘  └─────────────────┘  └──────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│  TRIGGER EVENTS                                                      │
│  ┌───────────────────────────┐  ┌───────────────────────────────┐   │
│  │ Push to main              │  │ Pull Request → main           │   │
│  │ → Lint+Test + Build+Push  │  │ → Lint+Test only (no push)    │   │
│  └───────────────────────────┘  └───────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│  CONCURRENCY CONTROL                                                 │
│  • Cancel in-progress runs when new commits are pushed              │
│  • Aggressive timeouts to prevent hung jobs                         │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 1: LINT & TEST                                                │
│  • Runner: self-hosted linux                                        │
│  • Build Dockerfile.test → docker run                               │
│  • golangci-lint + unit tests (inside container)                    │
│  • Timeout: 10 min                                                  │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │ Pass
                                  ▼
                    ┌─────────────────────────────┐
                    │  Check Event Type           │
                    └─────────────┬───────────────┘
                                  │
                ┌─────────────────┴─────────────────┐
                │                                   │
                ▼                                   ▼
┌───────────────────────────┐         ┌────────────────────────────────┐
│  Pull Request             │         │  Push to main                  │
│  → Stop (no build/push)   │         │  → Continue to Stage 2         │
└───────────────────────────┘         └───────────────┬────────────────┘
                                                      │
                                                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 2: BUILD & PUSH                                               │
│  • Runner: self-hosted linux                                        │
│  • Multi-stage Dockerfile                                           │
│  • Push to GitHub Container Registry (ghcr.io)                     │
│  • Timeout: 15 min                                                  │
│                                                                      │
│  Output Tags:                                                        │
│  • main-abc1234  (Git SHA — immutable)                              │
│  • main          (branch — mutable)                                 │
│  • latest        (mutable, main only)                               │
└─────────────────────────────────────────────────────────────────────┘
```

### Pipeline Stages

| Stage | Timeout | Purpose |
|-------|---------|---------|
| **Lint & Test** | 10 min | golangci-lint + unit tests via Dockerfile.test |
| **Build & Push** | 15 min | Build multi-stage Dockerfile & push to registry |

---

## Design Decisions

### 1. Resource Contention

**Challenge**: 5 台 servers，每台可能同時跑 3+ jobs（共 15+ concurrent jobs）

**Solution A: Docker Container Isolation**

每個 job 在獨立的 Docker container 中執行，process 和 filesystem 互相隔離。即使同一台 server 同時跑 3 個 jobs，也不會互相干擾或造成 state 污染，最多只是 CPU/memory 的競爭。

**Solution B: Concurrency Control**

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

當開發者 push 新 commits 到同一 PR 時，舊的 build 自動取消，減少 queue 堆積。

**Solution C: Aggressive Timeouts**

| Job | Timeout |
|-----|---------|
| Lint & Test | 10 min |
| Build & Push | 15 min |

防止 hung jobs 長時間佔用 runners。

---

### 2. Scalability

**Challenge**: Pipeline 需擴展至多個 microservice repositories，避免重複維護

**Solution: Reusable Workflow Architecture**

此 repo 的 [`.github/workflows/go-service-ci.yml`](.github/workflows/go-service-ci.yml) 即為中央 reusable workflow，其他 microservice repo 直接 `uses` 它：

```
sample-code/                               ← 此 repo（中央 workflow）
└── .github/workflows/
    ├── ci.yml                             ← 本 repo 自己的 pipeline
    └── go-service-ci.yml                 ← Reusable workflow（供其他 repos 呼叫）

user-service/                              ← Microservice A
└── .github/workflows/ci.yml              ← ~15 行，呼叫 reusable workflow

order-service/                             ← Microservice B
└── .github/workflows/ci.yml              ← ~15 行，呼叫 reusable workflow
```

**每個 Microservice 只需 ~15 行**:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  ci:
    uses: <org>/sample-code/.github/workflows/go-service-ci.yml@main
    with:
      image-name: ${{ github.repository }}
    secrets: inherit
```

**Benefits**:
- **DRY**: CI 邏輯只定義一次，所有 repos 共用
- **一致性**: 所有 services 使用相同 build process
- **易維護**: 更新 `go-service-ci.yml`，所有 services 自動套用
- **快速 onboarding**: 新 service 5 分鐘內加入 CI

---

### 3. Tagging Strategy

**Challenge**: Image 版本需支援開發、測試、生產環境，並維持可追溯性

| Tag Type | Example | Mutable | Use Case |
|----------|---------|---------|----------|
| **Git SHA** | `main-abc1234` | ❌ Immutable | Production deployment, rollback |
| **Branch** | `main` | ✅ Mutable | Auto-deploy to staging |
| **Latest** | `latest` | ✅ Mutable | Default pull target |

**Why Git SHA?**

`latest` 和 `main` 是 mutable 的，每次 push 都會被覆蓋，rollback 時無法知道上一個版本指向哪個 commit。Git SHA tag 是 immutable 的，出事時可以精確 rollback 到任意歷史版本。

**Best Practice**:

```yaml
# ✅ Production: 使用 immutable tags
image: ghcr.io/org/service:main-abc1234

# ❌ Production: 避免 mutable tags
image: ghcr.io/org/service:latest
```

**Rollback 範例**:
```bash
kubectl set image deployment/app container=ghcr.io/org/service:main-def5678
```

---

### 4. Security

**Challenge**: 安全管理 registry credentials，不在 code 或 logs 中暴露 secrets

**Solution: GitHub Secrets + Least Privilege**

```yaml
permissions:
  contents: read   # 只讀 source code
  packages: write  # 只寫 container images

steps:
  - uses: docker/login-action@v3
    with:
      registry: ghcr.io
      username: ${{ github.actor }}
      password: ${{ secrets.GITHUB_TOKEN }}  # Auto-provided, 無需手動設定
```

`GITHUB_TOKEN` 由 GitHub 自動產生，每次 workflow run 都是新 token，無 long-lived credentials 風險。

如需推送至雲端 registry（AWS ECR / Azure ACR），建議改用 **OIDC**：

```yaml
permissions:
  id-token: write
  contents: read

- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
    aws-region: us-east-1
```

OIDC 的優勢：無 long-lived credentials、自動 token rotation、細粒度存取控制（per repo/branch）。

---

### 5. Branch Protection (as Code)

**Challenge**: Branch protection rules 需要以 code 管理，確保 CI 通過才能 merge，避免人為繞過

**Solution**: [`.github/workflows/setup-branch-protection.yml`](.github/workflows/setup-branch-protection.yml) — 透過 `gh api` 自動套用 protection rules

```
Rules applied to main branch:
  ✓ Require status check "Lint & Test" to pass before merge
  ✓ Require branches to be up to date before merge (strict)
  ✓ Require at least 1 approving PR review
  ✓ Dismiss stale reviews on new commits
  ✗ Force push disabled
  ✗ Branch deletion disabled
```

**Trigger**: 可手動執行（Actions → Setup Branch Protection → Run workflow），或在 CI 首次成功後自動執行。

**Why as code?**

手動在 GitHub UI 設定 branch protection 無法版本控制、也無法重現。以 workflow 形式儲存後：新 repo fork 後執行一次即套用，設定變更有 git history 可追蹤。

---

## Quick Start

```bash
# Run locally
go run main.go
curl http://localhost:8080/health  # Returns: OK

# Run tests
go test -v ./...

# Build with Docker
docker build -t simple-go-server .
docker run -p 8080:8080 simple-go-server
```

---

## Project Structure

```
.
├── .github/workflows/
│   ├── ci.yml                      # CI pipeline (本 repo)
│   ├── go-service-ci.yml           # Reusable workflow (供其他 repos 呼叫)
│   └── setup-branch-protection.yml # Branch protection as code
├── Dockerfile                      # Production multi-stage build
├── Dockerfile.test                 # Testing/linting environment
├── .golangci.yml                   # Linting configuration
├── main.go                         # Application code
├── main_test.go                    # Unit tests
└── README.md                       # This file
```
