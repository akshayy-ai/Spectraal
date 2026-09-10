# Spectraal SpecPilot — Specification Framework

A multi-stage AI-powered specification pipeline that transforms raw requirements into structured, validated specification documents before code generation begins.

## Why SpecPilot?

The old pipeline went **raw text → single spec.json → code**. This is fragile:
- Ambiguous requirements lead to missing features
- No formal data model before code gen = inconsistent APIs
- UI design decided ad-hoc during generation
- No traceability from requirement → implementation

SpecPilot adds a **5-stage specification pipeline** between requirements and code, inspired by:
- **OpenSpec** — SHALL statements, GIVEN/WHEN/THEN scenarios, 3-dimension validation
- **GitHub SpecPilot** — Constitution → Specify → Plan → Tasks workflow
- **BMAD-METHOD** — Role-based AI personas with clear boundaries

## Pipeline Stages

```
Raw Text → [0: Ingest] → [1: Architect] → [2: UI Design] → [3: Tasks] → [4: Validate] → Code Gen
              │              │                │               │              │
              ▼              ▼                ▼               ▼              ▼
          prd.json    architecture.json   ui-spec.json    tasks.json    validation.json
```

### Stage 0: Requirements Ingestion (Product Manager)
**Input:** Raw text requirements  
**Output:** `prd.json` + `prd.md`

- Expands vague requirements into formal user stories (US-xxx)
- Generates SHALL requirements with GIVEN/WHEN/THEN scenarios (REQ-xxx)
- Infers implicit features (login → registration, dashboard → stats)
- Sets priority levels (must-have / should-have / nice-to-have)

### Stage 1: Architecture Design (Software Architect)
**Input:** `prd.json`  
**Output:** `architecture.json`

- Selects tech stack with rationale
- Designs complete data model (entities, fields, relations, enums)
- Defines every API endpoint contract (method, path, request/response)
- Plans authentication and seed data

### Stage 2: UI/UX Specification (UI Designer)
**Input:** `prd.json` + `architecture.json`  
**Output:** `ui-spec.json`

- Selects domain-adaptive theme (colors, branding, gradients)
- Designs navigation structure
- Specifies page layouts section by section
- Maps every API endpoint to a UI component

### Stage 3: Task Decomposition (Tech Lead)
**Input:** `prd.json` + `architecture.json` + `ui-spec.json`  
**Output:** `tasks.json`

- Breaks architecture into ordered implementation tasks (T-xxx)
- Groups into 8 standard phases (schema → seed → integration)
- Creates test cases for every requirement scenario (TC-xxx)
- Maps dependencies to ensure correct execution order

### Stage 4: Cross-Validation (QA Architect)
**Input:** All 4 documents  
**Output:** `validation.json`

- **Completeness**: Every requirement traces to API → DB → UI → Task → Test
- **Correctness**: Field names match, response shapes fit UI needs, no circular deps
- **Coherence**: Naming conventions consistent, theme matches domain
- Builds full traceability matrix
- Blocks code generation if critical issues found

## Usage

### Full Pipeline
```bash
./specpilot/scripts/run-specpilot.sh requirements.txt builds/my-app
```

### Individual Stages
```bash
./specpilot/scripts/00-ingest.sh requirements.txt builds/my-app
./specpilot/scripts/01-architect.sh builds/my-app
./specpilot/scripts/02-ui-designer.sh builds/my-app
./specpilot/scripts/03-task-planner.sh builds/my-app
./specpilot/scripts/04-validate.sh builds/my-app
```

### With Factory (integrated)
```bash
./factory.sh "Build me a CRM with contacts, deals, and pipeline tracking"
# SpecPilot runs automatically as Stage 0, then feeds into code generation
```

## Directory Structure

```
specpilot/
├── README.md              ← You are here
├── schemas/               ← JSON schemas for each document
│   ├── 00-prd.schema.json
│   ├── 01-architecture.schema.json
│   ├── 02-ui-spec.schema.json
│   ├── 03-tasks.schema.json
│   └── 04-validation.schema.json
├── prompts/               ← AI persona prompts for each stage
│   ├── 00-ingest.md       ← Product Manager
│   ├── 01-architect.md    ← Software Architect
│   ├── 02-ui-designer.md  ← UI/UX Designer
│   ├── 03-task-planner.md ← Tech Lead
│   └── 04-validator.md    ← QA Architect
└── scripts/               ← Pipeline scripts
    ├── run-specpilot.sh      ← Full pipeline orchestrator
    ├── 00-ingest.sh
    ├── 01-architect.sh
    ├── 02-ui-designer.sh
    ├── 03-task-planner.sh
    └── 04-validate.sh
```

## Key Concepts

### Traceability Matrix
Every requirement is traced end-to-end:

| REQ-xxx | User Story | API Endpoint | DB Entity | UI Page | Task | Test Case |
|---------|-----------|-------------|-----------|---------|------|-----------|
| REQ-AUTH-001 | US-001 | POST /api/auth/login | User | Login | T-004 | TC-001 |

Coverage: `full` (all columns), `partial` (1-2 missing), `missing` (3+ missing = CRITICAL)

### SHALL + GIVEN/WHEN/THEN
Requirements use formal language:
- **SHALL**: "The system SHALL allow users to filter tasks by status"
- **GIVEN**: precondition — "GIVEN a logged-in user on the tasks page"
- **WHEN**: trigger — "WHEN they select 'In Progress' from the status filter"
- **THEN**: outcome — "THEN only tasks with status 'in_progress' are displayed"

### Domain-Adaptive Theming
Each app gets a unique look based on its industry:

| Domain | Colors | Emoji | Style |
|--------|--------|-------|-------|
| Healthcare | emerald/teal | 🏥 | Clean, clinical |
| FinTech | blue/slate | 🏦 | Trust, precision |
| E-Commerce | orange/amber | 🛒 | Energetic, warm |
| EdTech | violet/pink | 📚 | Creative, modern |

## Integration with Factory

When `factory.sh` detects SpecPilot scripts, it runs them as Stage 0:

1. SpecPilot generates 5 structured spec documents
2. Factory merges them into a backward-compatible `spec.json`
3. Code generation reads both the merged spec AND individual SpecPilot docs
4. Task-by-task generation uses `tasks.json` for ordering
5. Validation uses `validation.json` test cases for verification
