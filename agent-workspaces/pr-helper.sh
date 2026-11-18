#!/usr/bin/env bash
# pr-helper: push the current branch and open a pull request on Gitea as the bot account ($GITEA_TOKEN).
# Usage: pr-helper "title" [body-file]     DRY_RUN=1 pr-helper ... shows what it would do.
# If a PR for this branch is already open, it only pushes and prints that PR's URL.
set -euo pipefail
title=${1:?usage: pr-helper "title" [body-file]}
body=""
[ -n "${2:-}" ] && body=$(cat "$2")
host=${GIT_HOST:-https://git.example.lan}
url=$(git remote get-url origin)
path=${url#"$host"/}
path=${path%.git}
branch=$(git rev-parse --abbrev-ref HEAD)
api="$host/api/v1/repos/$path"
# agent sessions have $GITEA_TOKEN; plain shells fall back to the token the startup script stored for git
token=${GITEA_TOKEN:-$(sed -n 's#^https://[^:]*:\([^@]*\)@git\.example\.lan$#\1#p' ~/.git-credentials 2>/dev/null | head -1)}
[ -n "$token" ] || { echo "pr-helper: no Gitea token (GITEA_TOKEN / ~/.git-credentials)" >&2; exit 1; }
auth="Authorization: token $token"
base=$(curl -fsS -H "$auth" "$api" | python3 -c 'import sys,json; print(json.load(sys.stdin)["default_branch"])')
if [ "$branch" = "$base" ] || [ "$branch" = HEAD ]; then
  echo "pr-helper: on '$branch'; create a feature branch first (git switch -c agent/<topic>)" >&2
  exit 1
fi
existing=$(curl -fsS -H "$auth" "$api/pulls?state=open&limit=50" |
  python3 -c 'import sys,json; b=sys.argv[1]; print(next((p["html_url"] for p in json.load(sys.stdin) if p["head"]["ref"]==b), ""))' "$branch")
if [ -n "${DRY_RUN:-}" ]; then
  echo "repo=$path base=$base head=$branch existing=${existing:-none}"
  exit 0
fi
# secrets gate for every commit on the branch (husky repos skip the global pre-commit hook)
git fetch -q origin "$base"
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks git --log-opts="origin/$base..HEAD" --redact --no-banner . ||
    { echo "pr-helper: gitleaks found a possible secret in the branch; not pushing" >&2; exit 1; }
else
  echo "pr-helper: gitleaks missing; not pushing" >&2; exit 1
fi
git push -u origin "$branch"
if [ -n "$existing" ]; then
  echo "updated: $existing"
  exit 0
fi
python3 -c 'import sys,json; print(json.dumps({"title":sys.argv[1],"body":sys.argv[2],"head":sys.argv[3],"base":sys.argv[4]}))' \
  "$title" "$body" "$branch" "$base" |
  curl -fsS -X POST -H "$auth" -H "Content-Type: application/json" -d @- "$api/pulls" |
  python3 -c 'import sys,json; print("opened:", json.load(sys.stdin)["html_url"])'
