# CI Pipeline Design Plan

## Overview

本文件為 Golang Web Server 專案的 CI Pipeline 設計規劃，基於 `docs/assignment.pdf` 需求撰寫。

**技術選擇**: GitHub Actions  
**基礎設施限制**: 5 台 Build Servers，每台可能同時運行 3+ 個 jobs

---

## CI Pipeline Architecture

### Pipeline Flow Diagram

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
└─────────────────────────────┬───────────────────────────────────────┘
                              │ Pass
                              ▼
                ┌─────────────────────────────┐
                │  Check Event Type           │
                └─────────────┬───────────────┘
                              │
            ┌─────────────────┴─────────────────┐
            │                                   │
            ▼                                   ▼
┌───────────────────────┐         ┌────────────────────────────────┐
│  Pull Request         │         │  Push to main                  │
│  → Stop (no push)     │         │  → Continue to Stage 2         │
└───────────────────────┘         └───────────────┬────────────────┘
                                                  │
                                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 2: BUILD & PUSH                                               │
│  • Runner: self-hosted linux                                        │
│  • Multi-stage Dockerfile                                           │
│  • Push to GitHub Container Registry (ghcr.io)                     │
│  • Timeout: 15 min                                                  │
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

- Lint & Test: 10 min
- Build & Push: 15 min

防止 hung jobs 長時間佔用 runner。

---

### 2. Scalability

**Challenge**: Pipeline 需擴展至多個 microservice repositories

**Solution: Reusable Workflow Architecture**

此 repo 的 `.github/workflows/go-service-ci.yml` 即為中央 reusable workflow：

```
sample-code/                               ← 此 repo（中央 workflow）
└── .github/workflows/
    ├── ci.yml                             ← 本 repo 自己的 pipeline
    └── go-service-ci.yml                 ← Reusable workflow（供其他 repos 呼叫）

user-service/                              ← Microservice A
└── .github/workflows/ci.yml              ← 15 行，呼叫 reusable workflow

order-service/                             ← Microservice B
└── .github/workflows/ci.yml              ← 15 行，呼叫 reusable workflow
```

**Per-Service Implementation (~15 lines)**:

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
- DRY: CI 邏輯只定義一次
- 一致性: 所有 services 使用相同 build process
- 快速 onboarding: 新 service 5 分鐘內加入 CI

---

### 3. Tagging Strategy

**Challenge**: Image 版本需支援開發、測試、生產環境，並維持可追溯性

| Tag Type | Example | Mutable | Use Case |
|----------|---------|---------|----------|
| **Git SHA** | `main-abc1234` | ❌ | Production, rollback |
| **Branch** | `main` | ✅ | Auto-deploy environments |
| **Latest** | `latest` | ✅ | Default pull target |

**Why Git SHA?**

`latest` 和 `main` 是 mutable 的，每次 push 都會被覆蓋，rollback 時無法知道上一個版本指向哪個 commit。Git SHA tag 是 immutable 的，出事時可以精確 rollback 到任意歷史版本。

**Tagging Logic** (via `docker/metadata-action`):

```yaml
tags: |
  type=sha,prefix={{branch}}-,format=short   # main-abc1234
  type=ref,event=branch                       # main
  type=raw,value=latest,enable={{is_default_branch}}
```

---

### 4. Security

**Challenge**: 安全管理 registry credentials，不在 code 或 logs 中暴露 secrets

**Solution A: GitHub Secrets (GHCR)**

```yaml
permissions:
  contents: read
  packages: write

- uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}  # Auto-provided
```

**Solution B: OIDC (Cloud Registries — AWS ECR / Azure ACR)**

```yaml
permissions:
  id-token: write
  contents: read

- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
    aws-region: us-east-1
```

**Benefits**: 無 long-lived credentials，自動 token rotation

**Best Practices**:
- Least privilege: 每個 job 只給必要 permissions
- Organization-level secrets 跨 repos 共享

---

### 5. Branch Protection

**Solution**: 在 GitHub UI（Settings → Branches）手動設定 main branch protection rules。

Rules applied to `main`:
- Require status check `Lint & Test` to pass before merging (strict)
- Require 1 approving PR review, dismiss stale reviews on new commits
- Disable force push and branch deletion

---

## Summary

| Design Decision | Solution |
|-----------------|----------|
| Resource Contention | Docker isolation + Concurrency control + Timeouts |
| Scalability | Reusable workflow architecture |
| Tagging Strategy | SHA + Branch + Latest |
| Security | GITHUB_TOKEN / OIDC + Least privilege |
| Branch Protection | GitHub UI — require CI pass + PR review before merge |

---

**Document Version**: 1.1  
**Last Updated**: 2026-06-08
