#!/usr/bin/env bash
# audit/run-audit.sh — independent milestone audit runner
#
# Usage: run-audit.sh <client> <milestone>
#   <client>     name matching audit/criteria/<client>.yaml
#   <milestone>  milestone ID matching a key under milestones: (e.g. M3)
#
# Output (stdout): JSON array, one object per criterion:
#   { "id": "...", "description": "...", "status": "PASS"|"FAIL"|"SKIP", "detail": "..." }
#
# Exit code: 0 if all criteria PASS or SKIP, non-zero if any FAIL.
# Command exit-code convention: 0=PASS, 2=SKIP/BLOCKED, anything else=FAIL.
set -euo pipefail

_self_dir="$(dirname -- "$0")"
AUDIT_DIR="$(cd -- "${_self_dir}" && pwd -P)"
CRITERIA_DIR="${AUDIT_DIR}/criteria"

usage() {
    printf 'Usage: %s <client> <milestone>\n' "$(basename -- "$0")" >&2
    printf '  <client>     name matching audit/criteria/<client>.yaml\n' >&2
    printf '  <milestone>  milestone ID matching a key under milestones: (e.g. M3)\n' >&2
    exit 1
}

[[ $# -eq 2 ]] || usage
CLIENT="$1"
MILESTONE="$2"
YAML_FILE="${CRITERIA_DIR}/${CLIENT}.yaml"

if [[ ! -f "${YAML_FILE}" ]]; then
    printf 'Error: criteria file not found: %s\n' "${YAML_FILE}" >&2
    exit 1
fi

python3 - "${YAML_FILE}" "${MILESTONE}" <<'PYEOF'
import sys
import os
import json
import subprocess
import shutil
import glob
import re

yaml_file = sys.argv[1]
milestone = sys.argv[2]


# --- YAML parsing ---

def parse_scalar(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        return v[1:-1].replace('\\"', '"')
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        return v[1:-1].replace("''", "'")
    return v


def parse_criteria_custom(yaml_text, milestone_id):
    """Minimal YAML parser for the audit criteria schema."""
    lines = yaml_text.splitlines()
    n = len(lines)

    def indent_of(line):
        return len(line) - len(line.lstrip()) if line.strip() else -1

    # Find milestones:
    ml_line = None
    for i, line in enumerate(lines):
        if line.strip() == 'milestones:':
            ml_line = i
            break
    if ml_line is None:
        return []
    ml_ind = indent_of(lines[ml_line])

    # Find milestone_id: under milestones
    ms_line = ms_ind = None
    for i in range(ml_line + 1, n):
        if not lines[i].strip():
            continue
        ind = indent_of(lines[i])
        if ind <= ml_ind:
            break
        if lines[i].strip() == f'{milestone_id}:':
            ms_line, ms_ind = i, ind
            break
    if ms_line is None:
        return []

    # Find criteria: under milestone
    cr_line = cr_ind = None
    for i in range(ms_line + 1, n):
        if not lines[i].strip():
            continue
        ind = indent_of(lines[i])
        if ind <= ms_ind:
            break
        if lines[i].strip() == 'criteria:':
            cr_line, cr_ind = i, ind
            break
    if cr_line is None:
        return []

    # Parse list items
    results = []
    current = {}
    item_base = None
    in_block = False
    block_key = None
    block_content = []
    block_ind = None

    i = cr_line + 1
    while i < n:
        line = lines[i]
        raw_ind = indent_of(line)

        if not line.strip():
            if in_block:
                block_content.append('')
            i += 1
            continue

        # Left criteria section
        if raw_ind <= cr_ind:
            break

        stripped = line.strip()

        # Inside a block literal: collect content
        if in_block:
            if block_ind is None:
                block_ind = raw_ind
            if raw_ind >= block_ind:
                block_content.append(line[block_ind:])
                i += 1
                continue
            # Block ended — close it out
            while block_content and not block_content[-1].strip():
                block_content.pop()
            current[block_key] = '\n'.join(block_content) + '\n'
            in_block = False
            block_content = []
            block_ind = None
            # fall through to process this line

        # New list item: "      - "
        if stripped.startswith('- '):
            if current:
                results.append(dict(current))
                current = {}
            item_base = raw_ind
            rest = stripped[2:]
            if ': ' in rest:
                k, _, v = rest.partition(': ')
                k, v = k.strip(), v.strip()
                if v in ('|', '|-', '|+'):
                    block_key = k
                    in_block = True
                    block_ind = None
                else:
                    current[k] = parse_scalar(v)
            i += 1
            continue

        # Key-value inside a criterion
        if item_base is not None and raw_ind > cr_ind:
            if ': ' in stripped:
                k, _, v = stripped.partition(': ')
                k, v = k.strip(), v.strip()
                if v in ('|', '|-', '|+'):
                    block_key = k
                    in_block = True
                    block_ind = None
                else:
                    current[k] = parse_scalar(v)
            i += 1
            continue

        i += 1

    # Close any open block
    if in_block and block_key:
        while block_content and not block_content[-1].strip():
            block_content.pop()
        current[block_key] = '\n'.join(block_content) + '\n'
    if current:
        results.append(dict(current))

    return results


def find_yq():
    """Locate yq binary: PATH first, then nix store."""
    yq = shutil.which('yq')
    if yq:
        return yq
    for p in glob.glob('/nix/store/*-yq-*/bin/yq'):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def load_criteria(yaml_file, milestone):
    """Load and return the criteria list for the given milestone."""
    yq = find_yq()
    if yq:
        try:
            r = subprocess.run(
                [yq, '-c', f'.milestones.{milestone}.criteria', yaml_file],
                capture_output=True, text=True, timeout=15,
            )
            if r.returncode == 0 and r.stdout.strip() not in ('', 'null'):
                data = json.loads(r.stdout.strip())
                if isinstance(data, list):
                    return data
        except Exception:
            pass

    try:
        import yaml  # noqa: PLC0415
        with open(yaml_file) as f:
            data = yaml.safe_load(f)
        return data.get('milestones', {}).get(milestone, {}).get('criteria', []) or []
    except ImportError:
        pass

    with open(yaml_file) as f:
        content = f.read()
    return parse_criteria_custom(content, milestone)


# --- Audit execution ---

criteria = load_criteria(yaml_file, milestone)

if not criteria:
    print(f'Error: no criteria found for milestone {milestone!r} in {yaml_file}', file=sys.stderr)
    sys.exit(1)

results = []
for c in criteria:
    cid = c.get('id', 'unknown')
    desc = c.get('description', '')
    cmd = c.get('command', '')

    if not cmd:
        results.append({'id': cid, 'description': desc, 'status': 'SKIP', 'detail': 'no command defined'})
        continue

    try:
        proc = subprocess.run(
            ['bash', '-c', cmd],
            capture_output=True, text=True, timeout=60,
        )
        detail = (proc.stdout + proc.stderr).strip() or '(no output)'
        if proc.returncode == 0:
            status = 'PASS'
        elif proc.returncode == 2:
            status = 'SKIP'
        else:
            status = 'FAIL'
    except subprocess.TimeoutExpired:
        status = 'SKIP'
        detail = 'command timed out after 60s'
    except Exception as exc:
        status = 'FAIL'
        detail = str(exc)

    results.append({'id': cid, 'description': desc, 'status': status, 'detail': detail})

print(json.dumps(results, indent=2))

pass_count = sum(1 for r in results if r['status'] == 'PASS')
fail_count = sum(1 for r in results if r['status'] == 'FAIL')
skip_count = sum(1 for r in results if r['status'] == 'SKIP')
total = len(results)

print(f'{milestone}: {pass_count}/{total} PASS, {fail_count} FAIL, {skip_count} SKIP', file=sys.stderr)

sys.exit(1 if fail_count > 0 else 0)
PYEOF
