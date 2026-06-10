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
│  • main-abc1234  (Git SHA — immutable, for production/rollback)     │
│  • main          (branch — mutable, for staging auto-deploy)        │
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

#### Runner Infrastructure Options

本 pipeline 使用 `runs-on: [self-hosted, linux]`，支援以下兩種 runner 架構：

**Option A: 5 台 VM 各 1 Runner（傳統架構）**

```
┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
│  VM 1   │ │  VM 2   │ │  VM 3   │ │  VM 4   │ │  VM 5   │
│         │ │         │ │         │ │         │ │         │
│ Runner  │ │ Runner  │ │ Runner  │ │ Runner  │ │ Runner  │
│ Agent   │ │ Agent   │ │ Agent   │ │ Agent   │ │ Agent   │
│         │ │         │ │         │ │         │ │         │
│ Job A   │ │ Job D   │ │ Job G   │ │ Job J   │ │ Job M   │
│ Job B   │ │ Job E   │ │ Job H   │ │ Job K   │ │ Job N   │
│ Job C   │ │ Job F   │ │ Job I   │ │ Job L   │ │ Job O   │
└─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘
                    (每台 VM 同時跑 3+ jobs)
```

| 項目 | 說明 |
|------|------|
| **安裝方式** | 每台 VM 安裝 GitHub Actions Runner Agent |
| **並行設定** | 設定 `--max-workers` 或多個 runner instance |
| **優點** | 架構簡單、資源隔離、無單點故障 |
| **缺點** | 固定成本、無法動態擴縮 |
| **適合** | 穩定負載、On-premise 環境 |

Runner 是持久運行的 agent，需要手動清理 Docker images 避免磁碟空間耗盡（見 workflow 中的 `Cleanup test image` step）。

**Option B: Kubernetes + Actions Runner Controller（動態架構）**

```
┌─────────────────────────────────────────────────────────┐
│  Kubernetes Cluster (EKS / GKE / AKS / Self-managed)    │
│                                                         │
│  ┌─────────────────────────────────────┐                │
│  │  Actions Runner Controller (ARC)    │ ← 監聽 job queue│
│  │  • maxRunners: 5                    │                │
│  │  • minRunners: 0                    │                │
│  └──────────────────┬──────────────────┘                │
│                     │                                   │
│         Job 進來 → 動態建立 Runner Pod                   │
│                     │                                   │
│  ┌────────┐ ┌────────┐ ┌────────┐                      │
│  │Runner  │ │Runner  │ │Runner  │  ← 臨時 Pod          │
│  │Pod 1   │ │Pod 2   │ │Pod 3   │    Job 完成後銷毀    │
│  └────────┘ └────────┘ └────────┘                      │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

| 項目 | 說明 |
|------|------|
| **安裝方式** | 部署 ARC (actions-runner-controller) 到 K8s |
| **並行設定** | 透過 `maxRunners` 限制為 5 |
| **優點** | 動態擴縮、乾淨環境（Pod 銷毀後無殘留）、資源利用率高 |
| **缺點** | 架構複雜、需要 K8s 維運能力 |
| **適合** | 雲端環境、負載波動大、多團隊共用 |

動態 Runner Pod 在 job 結束後銷毀，無需手動清理 images，但 workflow 中的 cleanup step 仍保留作為防禦性設計。

**架構選擇建議**

| 考量因素 | 選 Option A (VM) | 選 Option B (K8s) |
|----------|------------------|-------------------|
| 現有基礎設施 | 已有 VM / On-premise | 已有 K8s cluster |
| 負載模式 | 穩定、可預測 | 波動大、尖峰明顯 |
| 維運能力 | 熟悉 VM 管理 | 熟悉 K8s |
| 成本考量 | 固定成本可接受 | 希望按需付費 |

---

**Solution A: Docker Container Isolation**

每個 job 在獨立的 Docker container 中執行，process 和 filesystem 互相隔離。即使同一台 server 同時跑 3 個 jobs，也不會互相干擾或造成 state 污染，最多只是 CPU/memory 的競爭。

**Solution B: Concurrency Control**

定義在 `ci.yml`（caller workflow），對整個 workflow run 生效，包含其呼叫的 `go-service-ci.yml`：

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

當開發者 push 新 commits 到同一 PR 時，舊的 build 自動取消，減少 queue 堆積。

**合併到 main 時的行為：**

```
09:00  PR1 合併 → CI 開始跑 ────╳ 被取消（沒有 push image）
09:01  PR2 合併 → CI 開始跑 ────→ ✅ 完成，push image
```

為了在 5 台 server 限制下避免 queue 過長，採用 cancel-in-progress 策略。最新的 commit 優先完成，舊的被取消。這意味著某些快速連續合併的 commit 可能沒有對應的 image，但 **SHA tag 確保每個成功 build 的 image 都可追溯**，需要時可精確 rollback。

| 情境 | 結果 |
|------|------|
| 快速連續合併多個 PR | 只有最後一個有 image |
| 需要 rollback | 使用最近成功 build 的 SHA tag |
| 一般開發流程 | 最新版本始終可用 |

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

此 repo 包含兩個 workflow：

- `ci.yml` — 本 repo 的 CI 入口（觸發條件、concurrency control），呼叫 `go-service-ci.yml`
- `go-service-ci.yml` — 共用 CI 邏輯（lint、test、build、push），供所有 repo 呼叫

`ci.yml` 透過相對路徑呼叫同 repo 的 reusable workflow：

```yaml
jobs:
  ci:
    uses: ./.github/workflows/go-service-ci.yml
    with:
      image-name: ${{ github.repository }}
    secrets: inherit
```

> **實務上**，`go-service-ci.yml` 應移至獨立的 central platform repo（如 `org/ci-platform`），各 application repo 的 `ci.yml` 改為呼叫 central repo 的 workflow。本 repo 暫時存放以示範設計概念。

```
ci-platform/                ← Central repo（實務理想架構）
└── .github/workflows/
    └── go-service-ci.yml   ← 共用邏輯，集中維護

sample-code/                ← 此 repo
user-service/               ← Microservice A
order-service/              ← Microservice B
  各自 ci.yml 只需 ~15 行，呼叫 central repo 的 workflow
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
    uses: <org>/ci-platform/.github/workflows/go-service-ci.yml@main
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

**Why Git SHA?**

`main` 是 mutable 的，每次 push 都會被覆蓋，rollback 時無法知道上一個版本指向哪個 commit。Git SHA tag 是 immutable 的，出事時可以精確 rollback 到任意歷史版本。

---

**兩種 CD 策略的 Tag 選擇**

Tag 的選擇應根據 CD 部署策略決定：

**策略 A：固定 Tag（簡單部署）**

Deployment manifest 直接寫死 mutable tag，每次 CI push 新 image 後，重啟 pod 即可拿到最新版本，無需修改任何設定：

```yaml
# deployment.yaml - 永遠拉最新的 main branch image
image: ghcr.io/org/service:main
```

適合：小團隊、快速迭代、staging 環境自動跟版。

**策略 B：GitOps（嚴謹部署）**

CI build 完成後，由 GitHub Action 自動更新 config repo 裡的 manifest，將 image tag 改為 SHA，並推 commit。ArgoCD / Flux 偵測到變更後自動部署：

```
CI build → image:main-abc1234
    │
    ▼
GitHub Action 更新 config repo
  image: ghcr.io/org/service:main-abc1234  ← 從 def5678 改為 abc1234
    │
    ▼
ArgoCD 偵測變更 → 自動 deploy
```

```yaml
# 每次部署都有對應的 git commit 紀錄
# rollback = git revert，清楚可追溯
image: ghcr.io/org/service:main-abc1234
```

適合：多環境（staging / prd 分開管理）、需要部署審計紀錄、正式生產環境。

本 repo 目前同時產生 SHA 和 branch tag，兩種策略皆可支援。

---

**Alternative: Semantic Versioning（進階）**

如果團隊有明確的 release 版本管理需求，可以改用 **git tag** 驅動 semantic version：

```bash
# 開發者打版本 tag
git tag v1.2.3
git push origin v1.2.3
```

CI 偵測到 `v*` tag event 時，自動產生對應的 image tags：

```
ghcr.io/org/service:v1.2.3    ← 精確版本（immutable）
ghcr.io/org/service:v1.2      ← minor 版本（mutable）
ghcr.io/org/service:latest    ← 最新 release
```

此方式讓 image 版本與產品 release 直接對應，適合有正式 release 流程的團隊。本 repo 目前採用 SHA-based tagging，無需人工管理版號，適合持續交付（CD）的開發模式。

---

### 4. Security

**Challenge**: 安全管理 registry credentials，不在 code 或 logs 中暴露 secrets

**Solution: GitHub Secrets + Least Privilege**

定義在 `go-service-ci.yml` 的 build job 中：

```yaml
permissions:
  contents: read   # 只讀 source code
  packages: write  # 只寫 container images

steps:
  - uses: docker/login-action@v3
    with:
      registry: ghcr.io
      username: ${{ github.actor }}
      password: ${{ secrets['registry-token'] || secrets.GITHUB_TOKEN }}
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

### 5. Branch Protection

Main branch 需在 GitHub UI（Settings → Branches）手動設定以下 protection rules，確保 CI 通過才能 merge：

- Require status check **"Lint & Test"** to pass before merging
- Require branches to be up to date before merging
- Require at least 1 approving PR review
- Disable force push and branch deletion

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
│   ├── ci.yml                      # CI 入口：觸發條件 & concurrency control，呼叫 go-service-ci.yml
│   └── go-service-ci.yml           # Reusable workflow：lint、test、build、push 邏輯
├── Dockerfile                      # Production multi-stage build
├── Dockerfile.test                 # Testing/linting environment
├── .golangci.yml                   # Linting configuration
├── main.go                         # Application code
├── main_test.go                    # Unit tests
└── README.md                       # This file
```
