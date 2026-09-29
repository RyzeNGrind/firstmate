# Audit Framework

Independent milestone verification for client projects.
Every verdict is re-derived from the live URL, repo, or artifact at run time.

## Independence rule

The auditor is never the builder, and every verdict is re-derived from the live URL, repo
or artifact, never from the builder's report; a milestone confirmed by its own builder is
worth nothing to a client asked to pay.

## Structure

```
audit/
  README.md              this file
  run-audit.sh           audit runner — reads criteria, executes commands, emits JSON
  criteria/
    nexverse.yaml        NexVerse Arcade criteria, M1–M4
```

## Usage

```
./audit/run-audit.sh <client> <milestone>
```

**Arguments:**

- `<client>` — name matching `audit/criteria/<client>.yaml` (e.g. `nexverse`)
- `<milestone>` — milestone ID matching a key under `milestones:` (e.g. `M3`)

**Example:**

```
./audit/run-audit.sh nexverse M3
```

**Output (stdout):** JSON array, one object per criterion:

```json
[
  {
    "id": "m3-http-root",
    "description": "Homepage / returns HTTP 200",
    "status": "PASS",
    "detail": ""
  },
  ...
]
```

**Stderr:** summary line — `M3: 12/15 PASS, 1 FAIL, 2 SKIP`

**Exit code:** `0` if all criteria are PASS or SKIP; non-zero if any FAIL.

## Command exit-code convention

Each criterion's `command:` field is a shell command run in a `bash -c` subshell.

| Exit code | Audit status | Meaning |
|-----------|-------------|---------|
| `0` | PASS | Criterion confirmed |
| `2` | SKIP | Cannot evaluate (BLOCKED, missing tool, or inaccessible resource) |
| anything else | FAIL | Criterion not confirmed |

## Criteria file format

```yaml
client: nexverse
sow_version: V5-T2-2025-11-18
live_url: https://nexverse.dasagency.ca
repo: das-grp/client-t2m1-landing

milestones:
  M1:
    name: "Foundation & Pre-Launch Marketing Infrastructure"
    amount_cad: 1125.00
    criteria:
      - id: <slug>
        description: <human-readable one-liner>
        command: <shell command — exits 0 on pass, 2 on skip, non-zero on fail>
```

Every criterion **must** have a `command:` field.
A criterion without a command is an opinion, not a criterion.

## Dependencies

- `bash` 4+
- `curl`
- `git` (for `git ls-remote` repo checks)
- `python3` (for YAML parsing and complex checks)
- `yq` (optional; used if found in `PATH` or `/nix/store/*-yq-*/bin/yq`)
- `PyYAML` (optional; used if available via `import yaml`)

The script falls back gracefully through `yq` → `PyYAML` → built-in minimal parser.

## Adding a new client

Create `audit/criteria/<client>.yaml` following the format above.
Derive criteria from the SoW delivered-scope text — not from the builder's signoff report.
The signoff is the artifact being audited, not the specification.
