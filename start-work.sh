#!/usr/bin/env bash
# start-work.sh <issue-number>
#
# SDC development workflow helper.
# Given a GitHub issue number:
#   1. Fetches issue title and labels from GitHub
#   2. Derives a branch prefix from labels (fix/, docs/, chore/, feat/)
#   3. Creates and pushes a branch: <prefix>/<n>-<slug>
#   4. Opens a draft PR linked to the issue
#
# Usage:
#   ./start-work.sh 42
#
# Requirements:
#   gh (GitHub CLI), git

set -euo pipefail

REPO="smalldreamcollective/roll-your-own-symphony"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <issue-number>" >&2
  exit 1
fi

ISSUE_NUMBER="$1"

# Fetch issue details
ISSUE_JSON=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title,labels 2>&1) || {
  echo "Error: could not fetch issue #$ISSUE_NUMBER" >&2
  exit 1
}

TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
LABELS=$(echo "$ISSUE_JSON" | jq -r '[.labels[].name] | join(",")')

# Derive branch prefix from labels
PREFIX="feat"
if echo "$LABELS" | grep -qiE '(^|,)(fix|bug)(,|$)'; then
  PREFIX="fix"
elif echo "$LABELS" | grep -qiE '(^|,)(docs|documentation)(,|$)'; then
  PREFIX="docs"
elif echo "$LABELS" | grep -qiE '(^|,)(chore)(,|$)'; then
  PREFIX="chore"
fi

# Slugify title: lowercase, spaces → dashes, strip non-alphanum-dash
SLUG=$(echo "$TITLE" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9 ]//g' \
  | sed -E 's/ +/-/g' \
  | sed 's/^-//;s/-$//' \
  | cut -c1-50)

BRANCH="${PREFIX}/${ISSUE_NUMBER}-${SLUG}"

echo "Issue:  #${ISSUE_NUMBER} — ${TITLE}"
echo "Labels: ${LABELS:-none}"
echo "Branch: ${BRANCH}"
echo ""

# Ensure we're on a clean main
git fetch origin main --quiet
git checkout main --quiet
git pull --rebase origin main --quiet

git checkout -b "$BRANCH"
git push -u origin "$BRANCH" --quiet

# Open a draft PR
PR_URL=$(gh pr create \
  --repo "$REPO" \
  --title "$TITLE" \
  --body "Closes #${ISSUE_NUMBER}" \
  --head "$BRANCH" \
  --base main \
  --draft)

echo "Draft PR: $PR_URL"
