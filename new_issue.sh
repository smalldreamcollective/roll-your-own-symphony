#!/usr/bin/env bash
# Usage: ./new_issue.sh "Issue title" "Description text"
# Or:    ./new_issue.sh  (interactive mode)

ISSUES_DIR="$(dirname "$0")/issues"

# Find next issue number
next_id() {
  local max=0
  for f in "$ISSUES_DIR"/ISSUE-*.yaml; do
    [[ -f "$f" ]] || continue
    n="${f##*ISSUE-}"
    n="${n%.yaml}"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > max )) && max=$n
  done
  echo $(( max + 1 ))
}

ID=$(next_id)
IDENTIFIER="ISSUE-$ID"
FILE="$ISSUES_DIR/$IDENTIFIER.yaml"

if [[ $# -ge 2 ]]; then
  TITLE="$1"
  DESCRIPTION="$2"
elif [[ $# -eq 1 ]]; then
  TITLE="$1"
  echo "Description (end with a line containing only '.'):"
  DESCRIPTION=""
  while IFS= read -r line; do
    [[ "$line" == "." ]] && break
    DESCRIPTION+="$line"$'\n'
  done
else
  echo -n "Title: "
  read -r TITLE
  echo "Description (end with a line containing only '.'):"
  DESCRIPTION=""
  while IFS= read -r line; do
    [[ "$line" == "." ]] && break
    DESCRIPTION+="$line"$'\n'
  done
fi

# Indent description for YAML block scalar
INDENTED=$(printf '%s' "$DESCRIPTION" | sed 's/^/  /')

cat > "$FILE" <<EOF
id: "$ID"
identifier: "$IDENTIFIER"
title: "$TITLE"
description: |
$INDENTED
state: "Todo"
priority: 2
labels:
  - test
EOF

echo "Created $FILE"
