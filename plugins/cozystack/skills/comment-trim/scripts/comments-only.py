#!/usr/bin/env python3
"""Verify that a change touches only comments.

Strips comments from both sides of a diff and compares what is left. If the
comment-free forms match, no code moved; that is the claim a comment trim needs
to be able to make, and eyeballing a large diff cannot establish it.

Usage:
    comments-only.py <base-rev> [<head-rev>]     # default head: working tree
    comments-only.py --files OLD NEW             # two files directly

Exit 0 when every changed file is comments-only, 1 when code changed, 2 on a
file whose language is not recognised (reported, never silently passed).
"""
import re
import subprocess
import sys

C_LIKE = {".go", ".c", ".h", ".cc", ".cpp", ".hpp", ".java", ".js", ".jsx",
          ".ts", ".tsx", ".rs", ".swift", ".kt", ".scala", ".cs", ".php",
          ".proto", ".dart", ".groovy"}
HASH = {".py", ".rb", ".sh", ".bash", ".zsh", ".yaml", ".yml", ".toml",
        ".tf", ".pl", ".r", ".jl", ".nix"}
DASH = {".sql", ".lua", ".hs", ".elm", ".ada"}


def strip_c_like(src):
    """Remove // and /* */ comments, respecting string, char and raw-string state."""
    out, i, n = [], 0, len(src)
    while i < n:
        ch = src[i]
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif ch == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
        elif ch == '"':
            out.append(ch)
            i += 1
            while i < n and src[i] != '"':
                if src[i] == "\\":
                    out.append(src[i])
                    i += 1
                if i < n:
                    out.append(src[i])
                    i += 1
            out.append('"')
            i += 1
        elif ch == "`":  # Go raw string: no escapes, spans lines
            out.append(ch)
            i += 1
            while i < n and src[i] != "`":
                out.append(src[i])
                i += 1
            out.append("`")
            i += 1
        elif ch == "'":
            # Char literal, or a Rust lifetime ('a) which never closes. Only
            # enter string state when a closing quote is plausibly near.
            close = src.find("'", i + 1, i + 6)
            if close == -1:
                out.append(ch)
                i += 1
            else:
                out.append(src[i:close + 1])
                i = close + 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def strip_linewise(src, marker):
    """Remove marker-to-end-of-line comments outside of quotes."""
    out = []
    for line in src.split("\n"):
        res, i, n, quote = [], 0, len(line), None
        while i < n:
            ch = line[i]
            if quote:
                res.append(ch)
                if ch == "\\" and i + 1 < n:
                    res.append(line[i + 1])
                    i += 2
                    continue
                if ch == quote:
                    quote = None
                i += 1
            elif ch in "\"'":
                quote = ch
                res.append(ch)
                i += 1
            elif line.startswith(marker, i):
                break
            else:
                res.append(ch)
                i += 1
        out.append("".join(res))
    return "\n".join(out)


def strip(src, ext):
    if ext in C_LIKE:
        return strip_c_like(src)
    if ext in HASH:
        return strip_linewise(src, "#")
    if ext in DASH:
        return strip_linewise(src, "--")
    return None


def normalize(src):
    """Collapse whitespace and drop blank lines: removing a comment leaves both."""
    lines = (re.sub(r"\s+", " ", ln).strip() for ln in src.split("\n"))
    return [ln for ln in lines if ln]


def show(path, ext, old, new):
    a, b = strip(old, ext), strip(new, ext)
    if a is None:
        print(f"  ?  {path}  (unknown extension '{ext}' — check by hand)")
        return 2
    a, b = normalize(a), normalize(b)
    if a == b:
        print(f"  ok {path}")
        return 0
    print(f"  !! {path}  CODE CHANGED")
    import difflib
    for ln in list(difflib.unified_diff(a, b, "before", "after", lineterm="", n=1))[:40]:
        print(f"       {ln}")
    return 1


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)


def main():
    if sys.argv[1:2] == ["--files"]:
        old_p, new_p = sys.argv[2], sys.argv[3]
        ext = "." + new_p.rsplit(".", 1)[-1]
        with open(old_p) as f:
            old = f.read()
        with open(new_p) as f:
            new = f.read()
        sys.exit(show(new_p, ext, old, new))

    if not sys.argv[1:]:
        print(__doc__)
        sys.exit(2)

    base = sys.argv[1]
    head = sys.argv[2] if len(sys.argv) > 2 else None

    rng = [base, head] if head else [base]
    files = [f for f in git("diff", "--name-only", *rng).stdout.split("\n") if f]
    if not files:
        print("no changed files")
        sys.exit(0)

    worst = 0
    for path in files:
        ext = "." + path.rsplit(".", 1)[-1] if "." in path else ""
        old = git("show", f"{base}:{path}").stdout
        new = git("show", f"{head}:{path}").stdout if head else open(path).read()
        worst = max(worst, show(path, ext, old, new))

    print()
    print({0: "COMMENTS ONLY — no code moved.",
           1: "CODE CHANGED — see the files marked !! above.",
           2: "INCONCLUSIVE — some files need a manual check."}[worst])
    sys.exit(worst)


if __name__ == "__main__":
    main()
