#!/bin/bash
# Enforces the module boundaries that keep this package buildable without Xcode.
#
# The rules below are the reason `swift build` works on a machine that has only Command Line Tools.
# They are easy to violate by accident — one `#Preview` added while polishing a view is enough to
# break the build for everyone without Xcode — so they are checked rather than trusted.
set -uo pipefail

cd "$(dirname "$0")/.."

FAILURES=0

fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

# Rule 1 — the Xcode-only macros must never appear in a target that CLT has to compile.
# Matches the macro at a use site (`@Model`, `#Preview {`) while ignoring prose in comments.
XCODE_ONLY_MACROS='(^|[^[:alnum:]_])(@Model|@Relationship|@Attribute|#Predicate|#Preview)([^[:alnum:]_]|$)'
for target in LggrKit LggrApp; do
    if [ ! -d "Sources/$target" ]; then
        continue
    fi
    while IFS= read -r file; do
        # Strip line comments before matching so documentation may still name the macros.
        if sed 's|//.*||' "$file" | grep -qE "$XCODE_ONLY_MACROS"; then
            fail "$file uses an Xcode-only macro. These belong in Sources/LggrPersistence/ only."
            sed 's|//.*||' "$file" | grep -nE "$XCODE_ONLY_MACROS" | head -3 | sed 's/^/       /'
        fi
    done < <(find "Sources/$target" -name '*.swift')
done

# Rule 2 — LggrKit is the domain layer. It must not reach for UI or persistence frameworks, so it
# stays testable, portable and free of main-actor assumptions.
if [ -d "Sources/LggrKit" ]; then
    while IFS= read -r file; do
        if grep -qE '^[[:space:]]*import[[:space:]]+(SwiftUI|AppKit|SwiftData|LggrApp|LggrPersistence)([[:space:]]|$)' "$file"; then
            fail "$file imports a UI or persistence framework. LggrKit must depend on Foundation only."
            grep -nE '^[[:space:]]*import[[:space:]]+(SwiftUI|AppKit|SwiftData|LggrApp|LggrPersistence)' "$file" | head -3 | sed 's/^/       /'
        fi
    done < <(find "Sources/LggrKit" -name '*.swift')
fi

# Rule 3 — only one file may know whether the SwiftData backend was compiled in. Scattering this
# conditional is how a codebase ends up with two divergent persistence paths.
if [ -d "Sources/LggrApp" ]; then
    OFFENDERS=$(grep -rlE '^[[:space:]]*#if[[:space:]]+canImport\(LggrPersistence\)' Sources/LggrApp --include='*.swift' \
        | grep -v 'StoreBootstrap.swift' || true)
    if [ -n "$OFFENDERS" ]; then
        fail "the LggrPersistence conditional must live only in StoreBootstrap.swift:"
        echo "$OFFENDERS" | sed 's/^/       /'
    fi
fi

# Rule 4 — force unwraps and force tries are banned outside test fixtures, per the coding
# expectations. `try!` and `as!` are unambiguous; a bare `!` is not, so only the explicit forms are
# checked here rather than guessing at optional-chaining syntax.
while IFS= read -r file; do
    if sed 's|//.*||' "$file" | grep -qE '(^|[^[:alnum:]_])(try!|as!)([^[:alnum:]_]|$)'; then
        fail "$file uses try! or as!. Handle the error explicitly."
        sed 's|//.*||' "$file" | grep -nE '(try!|as!)' | head -3 | sed 's/^/       /'
    fi
done < <(find Sources -name '*.swift' 2>/dev/null)

if [ "$FAILURES" -eq 0 ]; then
    echo "OK: module boundaries intact."
    exit 0
fi

echo ""
echo "$FAILURES layering violation(s). See docs/_design/CONSTRAINTS.md for why these rules exist."
exit 1
