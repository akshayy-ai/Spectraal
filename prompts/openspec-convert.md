# OpenSpec → Spectraal Conversion Prompt

You are converting OpenSpec Markdown specifications into Spectraal's JSON specification format.

## Input

You will receive the contents of one or more OpenSpec `.md` files from a repository. OpenSpec uses structured Markdown with RFC 2119 keywords (SHALL, MUST, SHOULD, MAY) and BDD-style scenarios (GIVEN/WHEN/THEN).

## Output

You MUST produce exactly 4 JSON files. Output each file as a fenced JSON block with a filename comment:

### 1. prd.json

```json
{
  "project_name": "kebab-case-name",
  "display_name": "Human Readable Name",
  "description": "One paragraph describing the application",
  "domain": "one of: saas|ecommerce|healthcare|fintech|education|logistics|social|productivity|analytics|other",
  "goals": ["list of 3-6 project goals extracted from specs"],
  "non_goals": ["list of 2-4 explicit non-goals or out-of-scope items"],
  "target_users": [
    {
      "role": "User role name",
      "description": "What this user does in the system"
    }
  ],
  "user_stories": [
    {
      "id": "US-001",
      "as_a": "role",
      "i_want": "capability",
      "so_that": "benefit",
      "priority": "must-have|should-have|nice-to-have",
      "acceptance_criteria": ["list of criteria"]
    }
  ],
  "requirements": "The original natural language requirements summary",
  "scope": {
    "features": [
      {
        "name": "Feature Name",
        "description": "What this feature does",
        "priority": "must-have|should-have|nice-to-have",
        "entities": ["Entity names involved"]
      }
    ]
  }
}
```

### 2. architecture.json

```json
{
  "stack": {
    "frontend": "react-tailwind",
    "backend": "node-express OR python-fastapi",
    "database": "postgresql",
    "rationale": "Why this stack fits"
  },
  "data_model": {
    "entities": [
      {
        "name": "EntityName",
        "description": "What this entity represents",
        "fields": [
          {
            "name": "fieldName",
            "type": "Int|String|Boolean|DateTime|Float|Enum|Json",
            "required": true,
            "unique": false,
            "description": "optional"
          }
        ],
        "relations": [
          {
            "field": "relationFieldName",
            "target": "TargetEntity",
            "type": "one-to-many|many-to-one|many-to-many|one-to-one",
            "on_delete": "cascade|restrict|set-null"
          }
        ]
      }
    ]
  },
  "api_contracts": [
    {
      "group": "Group Name",
      "base_path": "/api/resource",
      "auth_required": true,
      "endpoints": [
        {
          "method": "GET|POST|PUT|PATCH|DELETE",
          "path": "/",
          "description": "What this endpoint does",
          "request_body": {},
          "response": {},
          "auth": "required|optional|none",
          "roles": ["admin", "user"]
        }
      ]
    }
  ],
  "auth": {
    "strategy": "jwt",
    "roles": ["admin", "user"],
    "protected_routes": ["/api/*"],
    "public_routes": ["/api/auth/login", "/api/auth/register", "/api/health"]
  },
  "seed_data": {
    "users": [
      { "email": "admin@demo.com", "password": "admin123", "role": "admin", "name": "Admin User" },
      { "email": "user@demo.com", "password": "user123", "role": "user", "name": "Demo User" }
    ]
  }
}
```

### 3. ui-spec.json

```json
{
  "theme": {
    "archetype": "DASHBOARD|SAAS|CONSUMER|MARKETPLACE|CLINICAL|ITSM",
    "primary_color": "#hex",
    "accent_color": "#hex",
    "style": "modern|minimal|corporate|playful"
  },
  "navigation": {
    "type": "sidebar|top-nav",
    "items": [
      { "label": "Nav Item", "route": "/path", "icon": "icon-name", "roles": ["admin", "user"] }
    ]
  },
  "pages": [
    {
      "name": "PageName",
      "route": "/path",
      "type": "list|detail|form|dashboard|auth|settings|landing",
      "description": "What this page shows",
      "components": ["component names"],
      "access": "public|authenticated|admin"
    }
  ]
}
```

### 4. tasks.json

```json
{
  "phases": [
    {
      "name": "Phase Name",
      "tasks": [
        {
          "id": "T-001",
          "title": "Task title",
          "description": "What to implement",
          "type": "backend|frontend|fullstack|config",
          "priority": "critical|high|medium|low",
          "dependencies": ["T-000"]
        }
      ]
    }
  ]
}
```

## Conversion Rules

1. **SHALL/MUST** requirements → `must-have` priority
2. **SHOULD** requirements → `should-have` priority
3. **MAY** requirements → `nice-to-have` priority
4. **GIVEN/WHEN/THEN** scenarios → acceptance criteria in user stories
5. Every entity mentioned in specs MUST appear in the data model with proper fields and relations
6. Every user action in specs MUST have a corresponding API endpoint
7. Every page/view mentioned MUST appear in the pages array
8. If specs mention Python/FastAPI, set backend to `python-fastapi`; otherwise default to `node-express`
9. Always include auth (login/register) even if not explicitly in specs
10. Always include an admin user in seed data
11. Derive the design archetype from the domain (e.g., internal tools → DASHBOARD, customer-facing SaaS → SAAS)
12. If the OpenSpec repo has a `config.yaml`, use its `project_name` field

## Important

- Output ONLY the 4 JSON blocks with filename comments, no other text
- Each JSON must be valid and parseable
- Be thorough — extract EVERY requirement, entity, endpoint, and page from the specs
- When specs are ambiguous, make reasonable assumptions and include them
