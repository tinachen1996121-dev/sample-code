# Project Guidelines - CI Pipeline Assignment

This project follows the requirements defined in `docs/assignment.pdf`. All development actions MUST comply with these guidelines.

---

## Document Hierarchy (重要)

```
docs/assignment.pdf    ← 源頭需求 (NEVER MODIFY)
        │
        ├── CLAUDE.md          ← 專案開發指南 (衍生文件)
        ├── docs/plan.md       ← 設計規劃文件 (衍生文件)
        └── README.md          ← 專案說明文件 (衍生文件)
```

### 核心原則

1. **`docs/assignment.pdf` 是整個 Repo 的源頭需求**
   - 所有設計決策、實作方向都必須以此為依據
   - **永遠不可更改** - 這是不可變的需求規格

2. **衍生文件必須保持一致性**
   - `CLAUDE.md` - 開發指南，確保所有行為符合 assignment
   - `docs/plan.md` - 詳細設計規劃，基於 assignment 延伸
   - `README.md` - 專案說明，呈現 assignment 要求的交付內容

3. **變更流程**
   ```
   任何變更請求
        │
        ▼
   ┌─────────────────────────────┐
   │ 檢查是否符合 assignment.pdf │
   └─────────────────────────────┘
        │
        ├── 不符合 → ❌ 拒絕變更
        │
        └── 符合 → ✅ 執行變更
                      │
                      ▼
              ┌─────────────────────────┐
              │ 更新所有相關衍生文件:    │
              │ • CLAUDE.md             │
              │ • docs/plan.md          │
              │ • README.md             │
              │ • .github/workflows/*   │
              └─────────────────────────┘
   ```

### 變更檢查清單

在進行任何修改前，必須確認：

- [ ] 變更是否符合 `docs/assignment.pdf` 的需求？
- [ ] 是否影響 Pipeline Stages (Lint → Test → Build → Push)？
- [ ] 是否影響架構限制 (5 servers, 3+ concurrent jobs)？
- [ ] 是否影響 Design Decisions (Resource Contention, Scalability, Tagging, Security)？
- [ ] 所有衍生文件是否已同步更新？

### 禁止事項

```
⛔ 絕對禁止修改 docs/assignment.pdf
⛔ 禁止實作與 assignment 需求相違背的功能
⛔ 禁止更新部分文件而遺漏其他相關文件
```

---

## Project Context

This is a **Golang web server** CI pipeline implementation assignment. The goal is to design and implement an enterprise-grade CI pipeline that triggers automatically upon code commits.

**Source Repository:** https://github.com/danielhsu1/sample-code.git

**Project Components:**
- Simple Golang web server
- Unit tests
- `Dockerfile` - Production multi-stage build
- `Dockerfile.test` - Testing/linting environment

## Mandatory Requirements

### 1. CI Platform Choice

Use **one** of the following:
- **Jenkins** (`Jenkinsfile`)
- **GitHub Actions** (`.github/workflows/*.yml`)

### 2. Pipeline Stages (Required)

The pipeline MUST include these stages in order:

1. **Linting & Testing**
   - Use `Dockerfile.test` for the testing environment
   - Run `golangci-lint` for code linting
   - Execute unit tests

2. **Build Docker Image**
   - Only proceed if linting & testing pass
   - Use the provided multi-stage `Dockerfile`

3. **Push Docker Image** (implied by "final image push")
   - Push built image to container registry
   - Apply proper tagging strategy

### 3. Architectural Constraints

All designs MUST account for:

| Constraint | Requirement |
|------------|-------------|
| **Infrastructure** | Exactly 5 Build Servers (Nodes/Runners) |
| **Concurrency** | Single server may run 3+ jobs concurrently during peak |
| **Scalability** | Design must support multiple microservice repositories (company is adopting microservices architecture) |

## Deliverables Checklist

### CI Pipeline Code
- [ ] `Jenkinsfile` OR `.github/workflows/*.yml`

### README.md Must Include

- [ ] **CI Pipeline Diagram/Flowchart** showing:
  - Initial repository configurations:
    - Branch protection rules
    - Webhook settings
    - Trigger events (code commits)
  - Complete flow from trigger to final image push
  - All pipeline stages (lint → test → build → push)

- [ ] **Design Decision Explanations** for:
  - [ ] **Resource Contention**: How pipeline handles limited nodes & concurrent builds
  - [ ] **Scalability**: How pipeline can be reused across multiple repositories
  - [ ] **Tagging Strategy**: Docker image versioning approach
  - [ ] **Security**: Cloud credentials management for registry push

## Code Standards

### Golang
- Follow `golangci-lint` rules defined in `.golangci.yml`
- All code must pass linting before commit
- Unit tests must pass

### Docker
- Use multi-stage builds for production images
- Keep images minimal and secure

### CI/CD Best Practices
- Fail fast: Run quick checks (lint) before slow ones (build)
- Cache dependencies where possible
- Use semantic versioning for image tags
- Never hardcode credentials - use secrets management

## File Structure Reference

```
.
├── .github/workflows/     # GitHub Actions (if chosen)
│   ├── ci.yml             # Main pipeline for this repo
│   └── go-service-ci.yml  # Reusable workflow for microservices
├── Jenkinsfile            # Jenkins pipeline (if chosen)
├── Dockerfile             # Production multi-stage build
├── Dockerfile.test        # Testing/linting environment
├── .golangci.yml          # Linting configuration
├── docs/
│   └── assignment.pdf     # Original requirements
└── README.md              # Pipeline documentation (REQUIRED)
```

## Trigger Configuration

The pipeline MUST trigger automatically on:
- Push to main/master branch
- Pull request events (optional but recommended)

Consider implementing:
- Branch protection rules (require CI pass before merge)
- Webhook configurations for real-time triggers

## Prohibited Actions

- Do NOT skip linting or testing stages
- Do NOT hardcode credentials in pipeline code
- Do NOT ignore the 5-node infrastructure constraint
- Do NOT create designs that cannot scale to multiple repos
- Do NOT push images without proper tagging

## Quick Reference Commands

```bash
# Local testing with Docker
docker build -f Dockerfile.test -t app-test .
docker run app-test

# Production build
docker build -t app:latest .
```
