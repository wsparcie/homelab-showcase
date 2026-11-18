#!/bin/sh
# Global git hooks (core.hooksPath, written by the workspace startup script). pre-commit and pre-push run gitleaks; every hook
# then runs the repo's own .git/hooks/<name>, which a global hooksPath would otherwise skip. Repos that set their own
# core.hooksPath (husky) bypass this file; pr-helper and CI scan those commits instead.
name=$(basename "$0")
case "$name" in
  pre-commit)
    if command -v gitleaks >/dev/null 2>&1; then
      gitleaks git --pre-commit --staged --redact --no-banner . || {
        echo "gitleaks: a staged change looks like a secret. Remove it; a false positive goes into .gitleaksignore." >&2
        exit 1
      }
    fi ;;
  pre-push)
    if command -v gitleaks >/dev/null 2>&1; then
      up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo origin/main)
      gitleaks git --log-opts="$up..HEAD" --redact --no-banner . || { echo "gitleaks: secret in unpushed commits" >&2; exit 1; }
    fi ;;
esac
h="$(git rev-parse --git-dir)/hooks/$name"
[ -x "$h" ] && exec "$h" "$@"
exit 0
