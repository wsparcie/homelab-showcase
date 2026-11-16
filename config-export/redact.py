#!/usr/bin/env python3
"""Redact secrets in a tree of config files, in place. First line of defence before gitleaks.

Rules (value replaced by <REDACTED>, key/structure kept so the config stays readable):
  1. key = value / key: value / "key": "value" / <Key>value</Key> where the key name looks secret
  2. credentials in URLs  scheme://user:password@host
  3. well-known token formats anywhere (sk-..., glsa_, ghp_, github_pat_, gsk_, nvapi-, JWTs, PEM private keys, ...)
  4. Authorization: Bearer/Basic <value>, PVEAPIToken=...=<uuid>
Files that are secret by nature are deleted outright (see DROP).
"""
import os
import re
import sys

R = "<REDACTED>"
SECRET_KEY = (r"(?![A-Za-z0-9_.-]*(?:bypass|_path|_file|_dir|per_token|_cost|max_tokens|tokenizer|token_limit|passthrough|password_hash_algo|_url_path))(?:[A-Za-z0-9_.-]*?(?:pass(?:word|wd|phrase)?|secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key"
              r"|client[_-]?secret|auth[_-]?(?:key|token|value)|credential|salt|jwt|cookie[_-]?secret|session[_-]?secret"
              r"|encryption[_-]?key|webhook[_-]?url|dsn|database[_-]?url|db[_-]?url|redis[_-]?url|mongo(?:db)?[_-]?ur[il]"
              r"|bot[_-]?token|license[_-]?key|psk|wpa|smtp[_-]?pass|ldap[_-]?pass|enroll(?:ment)?[_-]?(?:key|pass)|master[_-]?key"
              r"|signing[_-]?key|hmac|otp|totp|seed|cipassword|authkey|ts_authkey|registration[_-]?shared|vapid[_-]?private|private|(?<![A-Za-z])key(?![A-Za-z])|_api(?![A-Za-z]))[A-Za-z0-9_.-]*)")
DROP = re.compile(r"(^|/)(secrets\.yaml|\.git-credentials|auth\.json|known_hosts|authorized_keys|credentials\.json"
                  r"|.*\.(pem|key|crt|p12|pfx|kdbx|db|sqlite3?)|id_(rsa|ed25519|ecdsa)(\.pub)?|shadow|gshadow"
                  r"|priv/.*|asp/.*|pve-token|grafana-mcp\.env|indexer-basic|krdp\.env|\.ide-key)$", re.I)

PATTERNS = [
    # PEM private key blocks
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), R),
    # env style: KEY=value (also export KEY=value), whole value
    (re.compile(r"(?im)^(\s*(?:export\s+)?" + SECRET_KEY + r"\s*=\s*)(?!<REDACTED>)(\"[^\"\n]*\"|'[^'\n]*'|[^\s#\n]+)"), r"\1" + R),
    # yaml: key: value  (skip values that are references like ${VAR}, os.environ/..., !secret, empty, true/false, numbers<6)
    (re.compile(r"(?im)^(\s*-?\s*[\"']?" + SECRET_KEY + r"[\"']?\s*:\s+)(?![\"']?(?:\$\{|os\.environ/|!secret|<REDACTED>|true\b|false\b|null\b|~|\[\]|\{\}))"
                r"(\"[^\"\n]+\"|'[^'\n]+'|[^\s#\n][^#\n]*?)(\s*(?:#.*)?)$"), r"\1" + R + r"\3"),
    # json: "key": "value"
    (re.compile(r"(?i)(\"" + SECRET_KEY + r"\"\s*:\s*)\"(?!<REDACTED>)[^\"]+\""), r'\1"' + R + '"'),
    # xml: <ApiKey>value</ApiKey>, <Password>..</Password>
    (re.compile(r"(?i)(<(" + SECRET_KEY + r")>)([^<]+)(</\2>)"), r"\1" + R + r"\4"),
    # ini/conf: key = value (no leading export), also "key value" for a few daemon formats
    (re.compile(r"(?im)^(\s*" + SECRET_KEY + r"\s*[=:]\s*)(?!<REDACTED>|\$\{)([^\s#;\n][^#;\n]*)$"), r"\1" + R),
    # credentials in URLs
    (re.compile(r"([a-z][a-z0-9+.-]*://[^\s:/@\"'<>]+:)([^\s@/\"'<>]+)(@)", re.I), r"\1" + R + r"\3"),
    # authorization headers
    (re.compile(r"(?i)((?:Bearer|Basic|token)\s+)(?!<REDACTED>|\$|\{)([A-Za-z0-9._~+/=-]{12,})"), r"\1" + R),
    (re.compile(r"(PVEAPIToken=[^=\s]+=)[0-9a-f-]{36}"), r"\1" + R),
    # well-known token formats
    (re.compile(r"\b(sk-(?:ant-|or-v1-|proj-)?[A-Za-z0-9_-]{16,}|glsa_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}"
                r"|gsk_[A-Za-z0-9]{30,}|nvapi-[A-Za-z0-9_-]{30,}|AIza[0-9A-Za-z_-]{30,}|AQ\.[A-Za-z0-9_-]{30,}|xox[abpr]-[A-Za-z0-9-]{20,}"
                r"|tskey-[A-Za-z0-9-]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})"), R),
    # wireguard / generic base64 keys after PrivateKey/PresharedKey
    (re.compile(r"(?im)^(\s*(?:PrivateKey|PresharedKey)\s*=\s*)\S+"), r"\1" + R),
]

import math
TOKEN = re.compile(r"[A-Za-z0-9+/=_\-.~]{24,}")
HARMLESS = re.compile(r"^(/[\w./-]+|sha(1|256|512)[:-]?[0-9a-f]+|[0-9a-f]{40}|[0-9a-f]{64}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
                      r"|AAAA[A-Za-z0-9+/]+=*|[\w.-]+\.(com|dev|org|net|io|lan|local|ai|json|yaml|yml|conf|py|sh|js)|[A-Za-z]+(_[A-Za-z0-9]+){2,}|[A-Za-z0-9]+(-[A-Za-z0-9]+){2,}|[A-Za-z]+(\.[A-Za-z0-9]+){2,})$")
LINE_OK = re.compile(r"(image:|@sha256:|digest|checksum|integrity|ssh-(ed25519|rsa) |os\.environ/|\$\{|env\(|getenv|open\(|vztmpl/|\.zst|\.tar)", re.I)


def entropy(s):
    c = {ch: s.count(ch) for ch in set(s)}
    return -sum(n / len(s) * math.log2(n / len(s)) for n in c.values())


def suspicious(tok):
    t = tok.strip("=.-_~")
    if re.fullmatch(r"[0-9a-fA-F]{32}|[0-9a-fA-F]{48}|[0-9a-fA-F]{96}", t):
        return True
    return (len(t) >= 24 and R not in t and not HARMLESS.match(t) and entropy(t) >= 4.2
            and re.search(r"\d", t) and re.search(r"[A-Za-z]", t))


def redact_entropy(text):
    out, n = [], 0
    for line in text.split("\n"):
        if not LINE_OK.search(line):
            def rep(m):
                nonlocal n
                if suspicious(m.group(0)):
                    n += 1
                    return R
                return m.group(0)
            line = TOKEN.sub(rep, line)
        out.append(line)
    return "\n".join(out), n


def redact_text(t):
    n = 0
    for rx, rep in PATTERNS:
        t, k = rx.subn(rep, t)
        n += k
    t, k = redact_entropy(t)
    return t, n + k


def main(root):
    dropped = changed = hits = 0
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            if DROP.search(rel):
                os.remove(p); dropped += 1; continue
            try:
                raw = open(p, "rb").read()
                t = raw.decode("utf-8")
            except (UnicodeDecodeError, OSError):
                os.remove(p); dropped += 1; continue      # binary or unreadable: never export
            new, n = redact_text(t)
            if n:
                open(p, "w", encoding="utf-8", newline="").write(new)
                changed += 1; hits += n
    print(f"redact: {changed} files changed, {hits} values redacted, {dropped} files dropped")


if __name__ == "__main__":
    main(sys.argv[1])
