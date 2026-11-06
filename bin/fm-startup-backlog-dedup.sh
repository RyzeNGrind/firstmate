#!/usr/bin/env bash
# Render three tasks-axi list responses without repeating identical records.
# Usage: fm-startup-backlog-dedup.sh <in-flight-file> <held-file> <blocked-file>
# Inputs are read-only snapshots, including tasks[N]{fields} and count headers.
# Each group keeps its membership through references to the first full record.
# Only byte-identical rows with identical schemas are shared; differing fields
# remain separate records. Invalid tables emit nothing and exit nonzero so the
# caller can use the complete manual backlog fallback.
set -eu
[ "$#" -eq 3 ] || exit 2
awk '
  FNR == 1 { group++; in_rows=0; help=0 }
  /^help\[/ { help=1 }
  help { next }
  /^count: [0-9]+$/ {
    if (counts[group] != "") bad=1
    counts[group]=$2; next
  }
  /^tasks: 0 (in_flight|held|blocked queued) tasks in this backlog$/ {
    if (headers[group] != "" || empty[group] != "") bad=1
    empty[group]=$0; expected[group]=0; next
  }
  /^tasks\[[0-9]+\]\{[^}]+\}:$/ {
    if (headers[group] != "" || empty[group] != "") bad=1
    headers[group]=$0
    schema=$0; sub(/^tasks\[[0-9]+\]/,"",schema)
    declared=$0; sub(/^tasks\[/,"",declared); sub(/\].*/,"",declared)
    expected[group]=declared+0; schemas[group]=schema; in_rows=1; next
  }
  in_rows && /^  / {
    rows[group]++
    key=schemas[group] SUBSEP $0
    if (key in origins) {
      refs[group]=refs[group] "  same record as " origins[key] "\n"
      duplicates[group]++
    } else {
      kept[group]++
      origins[key]=group ":" kept[group]
      bodies[group]=bodies[group] $0 "\n"
    }
    next
  }
  /^[[:space:]]*$/ { next }
  { bad=1 }
  END {
    if (group != 3) bad=1
    for (g=1;g<=3;g++)
      if ((headers[g] == "" && empty[g] == "") || counts[g] == "" || rows[g]+0 != expected[g] || counts[g]+0 != expected[g]) bad=1
    if (bad) exit 1
    labels[1]="in flight"; labels[2]="held (captain- or time-gated)"; labels[3]="blocked queued"
    for (g=1;g<=3;g++) {
      printf "\n%s (group %d):\n",labels[g],g
      printf "count: %d\n",kept[g]
      if (empty[g] != "") printf "%s\n",empty[g]
      else printf "tasks[%d]%s\n",kept[g],schemas[g]
      printf "%s",bodies[g]
      if (duplicates[g]) {
        printf "overlap references (group:row, counting full records only; %d):\n",duplicates[g]
        printf "%s",refs[g]
      }
    }
  }
' "$@"
