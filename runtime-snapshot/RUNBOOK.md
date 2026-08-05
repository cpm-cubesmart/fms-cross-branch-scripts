# runtime-snapshot runbook

Operating manual for comparing the runtime state of the classic-autoloader
branch against the Zeitwerk branch. Follow it top to bottom the first time;
after that you will live in [step 7](#7-the-convergence-loop).

For what the tool is and how it works internally, see the repository
`README.md`. This document is procedure only.

---

## Contents

1. [Before you start](#1-before-you-start)
2. [Verify the tooling](#2-verify-the-tooling)
3. [Build the rename map](#3-build-the-rename-map)
4. [Prove the snapshot is stable](#4-prove-the-snapshot-is-stable)
5. [The eager pair](#5-the-eager-pair)
6. [The non-eager pair](#6-the-non-eager-pair)
7. [The convergence loop](#7-the-convergence-loop)
8. [Reading the report](#8-reading-the-report)
9. [Triage with the ignore list](#9-triage-with-the-ignore-list)
10. [Option reference](#10-option-reference)
11. [Running without the wrappers](#11-running-without-the-wrappers)
12. [Troubleshooting](#12-troubleshooting)
13. [Output files](#13-output-files)

---

## 1. Before you start

Paths assumed throughout. Substitute your own if they differ:

| What | Where |
| --- | --- |
| classic branch | `~/code/fms` |
| Zeitwerk branch | `~/code/fms-worktrees/zeitwerk_upgrade_low_impact` |
| this repo | `~/code/fms-cross-branch-scripts` |

Run every command from `~/code/fms-cross-branch-scripts`. The wrappers resolve
their own locations and `cd` into the application themselves, so you never need
to be inside a checkout.

**The one manual step.** `config.eager_load` is set by hand in
`config/environments/development.rb`, in **both** checkouts, and the two must
match before you compare. This is deliberate — editing it gives a true
boot-time eager load, with initializers, `to_prepare` hooks and classic's
explicit requires interleaving exactly as they do in a real boot. Forcing
`Rails.application.eager_load!` from inside the runner would be more convenient
and less faithful.

`bin/snapshot` prints the `config.eager_load` line it found before it runs, and
`bin/compare` refuses to diff a mismatched pair, so a forgotten edit surfaces
immediately rather than as a confusing diff.

**Nothing is written to the application checkouts.** Snapshots go to
`runtime-snapshot/snapshots/`, which is gitignored.

---

## 2. Verify the tooling

```bash
cd ~/code/fms-cross-branch-scripts
runtime-snapshot/test/selftest.sh
```

Expected: `25 passed, 0 failed`.

It builds two throwaway applications in a temp directory and runs the real
dumper and comparator over them. No Rails, no database, no network, nothing
written outside `mktemp -d`. It asserts that:

- an unchanged checkout snapshots to identical bytes twice running, and
  comparing a snapshot to itself reports zero differences
- a constant that stops loading, a concern that stops being included, a
  decorator that loads before its class, and a method whose definition changes
  hands are each reported
- the rename map collapses moved-file findings to zero
- re-indenting a file is **not** reported as a source change
- mismatched `eager_load` is refused with exit 2
- `--exit-code` returns 1 with differences and 0 without
- the ignore list subtracts from the counts
- classes that override `name` / `ancestors` / `==` / `respond_to?` do not
  crash the dump, and a class that lies about its name is keyed by its real one

If this fails, stop. Nothing it reports about FMS would be trustworthy.

---

## 3. Build the rename map

The Zeitwerk branch moves a lot of files. Without a map, every moved file reads
as removed-here-added-there and the report is mostly noise.

```bash
runtime-snapshot/bin/renames ~/code/fms-worktrees/zeitwerk_upgrade_low_impact main
```

Writes `runtime-snapshot/snapshots/renames.json` and prints the rename count.
`bin/compare` picks it up automatically.

> **Standing rule:** re-run this whenever you move more files on the Zeitwerk
> branch. A stale map is worse than no map — it silently canonicalizes some
> paths and not others.

The second argument is the base ref and defaults to `main`. Renames are detected
from the merge-base, so it does not matter how far the branches have diverged.

---

## 4. Prove the snapshot is stable

Before comparing branches, compare `main` against itself. This validates the
comparator's "no differences" path against real application code — thousands of
constants, real gems, real monkey patches — rather than against fixtures.

```bash
runtime-snapshot/bin/snapshot ~/code/fms main-eager
runtime-snapshot/bin/snapshot ~/code/fms main-eager-again
runtime-snapshot/bin/compare  main-eager main-eager-again
```

Every count must be zero. If anything is non-zero, something in the snapshot is
non-deterministic and no cross-branch result can be believed until it is
explained.

Then read back the identity block:

```bash
ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["identity"]' \
  runtime-snapshot/snapshots/main-eager.json

ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["counts"]' \
  runtime-snapshot/snapshots/main-eager.json
```

Check three things:

| Field | Expected | If wrong |
| --- | --- | --- |
| `preboot_trace_installed` | `true` | `RUBYOPT` is not reaching Ruby. All load-order data is missing. See [troubleshooting](#12-troubleshooting). |
| `presumed_root_matched` | `true` | The preboot hook guessed the wrong root; class-body data is incomplete. |
| `counts.constants` | thousands | Tens means the scope filter found almost no application code — check `identity.root`. |

Also glance at `counts.skipped` (should be 0 or a small handful) and
`counts.duplicate_names` (should be 0).

---

## 5. The eager pair

Set `config.eager_load = true` in `config/environments/development.rb` in
**both** checkouts, then:

```bash
runtime-snapshot/bin/snapshot ~/code/fms                                       main-eager
runtime-snapshot/bin/snapshot ~/code/fms-worktrees/zeitwerk_upgrade_low_impact zeitwerk-eager
runtime-snapshot/bin/compare  main-eager zeitwerk-eager
```

Argument order matters: **classic first, Zeitwerk second**. The rename map runs
old → new, and the report is phrased as "present in A but missing in B".

---

## 6. The non-eager pair

Set `config.eager_load = false` in **both** checkouts, then the same three
commands with `-noeager` labels:

```bash
runtime-snapshot/bin/snapshot ~/code/fms                                       main-noeager
runtime-snapshot/bin/snapshot ~/code/fms-worktrees/zeitwerk_upgrade_low_impact zeitwerk-noeager
runtime-snapshot/bin/compare  main-noeager zeitwerk-noeager
```

This is the mode where classic's explicit requires in `config/application.rb`
did the most work, so expect the larger `constants_missing` list here. It is
also the mode your `to_prepare` initializers are being written to satisfy.

### Optional: establishing a noise floor

Comparing a branch against *itself* across the two modes tells you what eager
loading alone changes. Anything the cross-branch diff reports beyond that is
Zeitwerk-specific rather than a property of eager loading.

The comparator refuses these pairs outright — `eager_load` differs, so it exits
2 — and there is no flag to override it. The guard lives in the comparator, so
calling it directly does not bypass it either. If you want the noise floor, take
a copy of one snapshot and rewrite the field:

```bash
cd ~/code/fms-cross-branch-scripts/runtime-snapshot/snapshots

ruby -rjson -e '
  s = JSON.parse(File.read(ARGV[0]))
  s["identity"]["eager_load"] = ARGV[2] == "true"
  File.write(ARGV[1], JSON.generate(s))
' main-noeager.json main-noeager-asif.json true

cd ~/code/fms-cross-branch-scripts
runtime-snapshot/bin/compare main-eager main-noeager-asif
```

Only do this to a copy, and only for the noise-floor reading. The guard exists
because a mismatched pair produces a diff that looks alarming and means nothing;
defeating it by hand is a deliberate act, not a default.

---

## 7. The convergence loop

Only the Zeitwerk side changes as you work. Do not re-snapshot `main` unless it
has actually moved.

```bash
# 1. edit config/initializers on the zeitwerk branch
# 2. re-snapshot just that side
runtime-snapshot/bin/snapshot ~/code/fms-worktrees/zeitwerk_upgrade_low_impact zeitwerk-noeager

# 3. check the scoreboard
runtime-snapshot/bin/compare main-noeager zeitwerk-noeager --summary-only

# 4. read the worklist when you want detail
runtime-snapshot/bin/compare main-noeager zeitwerk-noeager
```

Drive the **semantic** counts to zero. Work top-down — `constants_missing`
first, since a constant that is not loaded at all also produces phantom entries
in most of the sections below it.

To script the loop, `--exit-code` returns 1 while semantic differences remain:

```bash
runtime-snapshot/bin/compare main-noeager zeitwerk-noeager --exit-code --summary-only \
  && echo "converged"
```

Keeping a record of progress across iterations:

```bash
runtime-snapshot/bin/compare main-noeager zeitwerk-noeager --format json \
  > /tmp/progress-$(date +%H%M).json
```

---

## 8. Reading the report

The header prints two groups. The distinction is the most important thing in
this document.

**Semantic** sections describe the runtime state itself — what actually exists
at runtime and how it behaves. These are the target.

**Informational** sections describe the mechanism that produced that state.
Zeitwerk eager-loads alphabetically per root directory, so its file ordering
will never match classic's `require` order. These exist to explain *why* a
semantic finding happened, not to be driven to zero.

### Semantic sections

| Section | Non-zero means | Usual fix |
| --- | --- | --- |
| `constants_missing` | A class or module that existed on classic is not loaded on Zeitwerk. **The primary worklist.** | A `to_prepare` block, or a missing eager-load path. |
| `constants_extra` | Something is loaded on Zeitwerk that was not on classic. | Usually benign, but check it is not a stale duplicate or an accidentally-eager-loaded file. |
| `superclass_changes` | A class now inherits from something different. | Almost always a load-order problem: the class was defined before its real parent was available. |
| `ancestor_diffs` | A module is included/prepended/extended differently, or in a different position. Order within the chain is significant — a `-`/`+` pair at different positions is a reordering, not a swap. | A concern that stopped being included, or a `prepend` that now lands on the wrong side. |
| `reopen_order_changes` | A class opened by more than one file now opens them in a different order. **Highest-signal section for this migration.** | See below. |
| `methods_removed` | A method defined on classic is absent on Zeitwerk. | The file defining it is not being loaded. |
| `methods_added` | A method exists on Zeitwerk that did not on classic. | Often the flip side of a reopen-order change — a definition that used to be overwritten now survives. |
| `visibility_changes` | Public/protected/private changed for a method. | A `private` declaration landing in a different reopening. |
| `source_diffs` | Same method name, different body. Prints the actual source diff. | The wrong definition is winning. |
| `signature_diffs` | Parameter list differs, for methods with no comparable source hash (native/gem). | Same as above. |
| `method_relocations` | Same method, identical source, different defining file. | Usually a rename the git map missed — refresh it ([step 3](#3-build-the-rename-map)). |

### Why `reopen_order_changes` matters most here

A class opened by more than one file — a model plus a decorator, a concern
mixed in after the fact, a monkey patch — has its final behavior decided by the
order those files run. Classic pinned that order with explicit `require`s in
`config/application.rb`. Zeitwerk does not.

The report shows the order on each side:

```
  Widget:
    main-noeager:     app/models/widget.rb -> lib/patches/widget_decorator.rb
    zeitwerk-noeager: lib/patches/widget_decorator.rb -> app/models/widget.rb
```

Read that as: on Zeitwerk the patch is applied *first* and then overwritten by
the original definition. No error is raised. The method silently reverts. This
is the failure mode the whole tool exists to catch, and it typically shows up
alongside a `source_diffs` entry for the affected method.

### Informational sections

| Section | Meaning |
| --- | --- |
| `files_only_a` / `files_only_b` | A file was loaded on one branch only. Worth scanning — a file in `files_only_a` often explains a `constants_missing` entry. |
| `load_order_moves` | The minimal set of files that had to move for the two orderings to match. **Expected to be large and never zero.** Computed as a longest-increasing-subsequence so it reports "these 40 files moved" rather than thousands of positional shifts. |
| `line_only_changes` | Same file, same source, different line number. Pure formatting churn. |

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Compared successfully. With `--exit-code`, also means no semantic differences. |
| 1 | Only with `--exit-code`: semantic differences remain. |
| 2 | Refused to compare (mismatched `RAILS_ENV`, `eager_load`, or script version), or a usage error. |

---

## 9. Triage with the ignore list

As you decide a difference is acceptable, record it so it stops reappearing and
the counts keep falling.

Create `runtime-snapshot/snapshots/ignore.txt` — `bin/compare` finds it
automatically. Start from `runtime-snapshot/ignore.example.txt`.

```
# Format: one rule per line, "<kind> <pattern>". Patterns are globs. # comments.

constant Legacy::*              # ignore a constant entirely
ancestor ActiveSupport::Fork*   # ignore a module wherever it appears in a chain
file     vendor/**              # ignore a file in the load-set/load-order sections
method   Widget#price           # instance method
method   Widget.build           # singleton method (note the dot)
section  line_only_changes      # ignore a whole section
```

Section ids are exactly the names printed in the counts header. An ignored
section still prints its count, marked `(ignored)`, and is excluded from the
semantic total.

`constant` is the broadest rule: ignoring a constant suppresses its ancestors,
methods, source and reopen-order findings too.

`constant` and `ancestor` are not the same axis. `constant` matches the chain
*owner* — the thing the row is reported against. `ancestor` matches a chain
*member*, striking that module out of every chain on both sides; a constant whose
only difference was that module then drops out of `ancestor_diffs` entirely, while
constants with a genuine difference keep their row minus the noise line. Reach for
`ancestor` when one module is prepended or included into `Object` on one side, so a
single global fact gets re-reported once per constant. Glob patterns cross `::`.

> Record **why** next to each entry. Six weeks from now the comment is the only
> thing left explaining the decision.

---

## 10. Option reference

### `bin/snapshot <app-dir> <label>`

| Variable | Default | Effect |
| --- | --- | --- |
| `RAILS_ENV` | `development` | Environment to boot. |
| `SNAPSHOT_DIR` | `runtime-snapshot/snapshots` | Where snapshots are written. |
| `SNAPSHOT_SOURCE_TEXT` | `1` | `0` skips capturing method bodies — smaller output, but the comparator can no longer print source diffs. |
| `SNAPSHOT_INCLUDE_ANONYMOUS` | `0` | `1` includes anonymous constants. |
| `SNAPSHOT_TRACE_COMPILE` | off | `1` also records `:script_compiled` events. Only meaningful with a cold Bootsnap cache. |
| `SNAPSHOT_TRACE_ALL` | off | `1` traces class bodies outside the app root too. Much larger output. |

Exits 2 if the target has no `config/environment.rb`.

### `bin/renames <zeitwerk-app-dir> [base-ref]`

`base-ref` defaults to `main`. Honours `SNAPSHOT_DIR`.

### `bin/compare <label-a> <label-b> [options]`

Everything after the two labels is passed through to the comparator. It supplies
`--renames` and `--ignore` automatically when those files exist.

| Flag | Effect |
| --- | --- |
| `--summary-only` | Counts header only. |
| `--exit-code` | Exit 1 while semantic differences remain. |
| `--strict` | With `--exit-code`, also fail on informational sections. Rarely what you want during this migration. |
| `--format text\|json` | `json` emits every section as structured data plus `counts`, `semantic_total`, `errors` and `warnings`. |
| `--max-per-section N` | Cap rows per section. Default 100; `0` for unlimited. Truncation is always announced, never silent. |
| `--no-source-diff` | List changed methods without printing their source diffs. |
| `--include-generated-ancestors` | Keep Rails' `Generated{Attribute,Association}Methods` in ancestor chains. Collapsed by default, because whether ActiveRecord has generated them yet is a timing artifact rather than a load-order fact. |
| `--include-zeitwerk-shims` | Keep `ActiveSupport::Dependencies::ZeitwerkIntegration::*` in ancestor chains. Collapsed by default: `take_over` does `Object.prepend(RequireDependency)`, so on the zeitwerk side it appears in every `Object`-descended chain and every singleton chain — one mode-switch fact re-reported once per constant, and the mode is already asserted from `identity`. |
| `--renames PATH` | Override the auto-detected rename map. |
| `--ignore PATH` | Override the auto-detected ignore list. |
| `--sources-a PATH` / `--sources-b PATH` | Override the source sidecars. Default: alongside each snapshot. |
| `-h`, `--help` | Full option list. |

---

## 11. Running without the wrappers

Use these when the wrapper's assumptions do not hold — a non-standard
`bin/rails`, a container, a different output location — or to see exactly what
the wrappers do.

**Snapshot.** The `RUBYOPT` preload is the essential part: `bin/rails runner`
executes its script *after* boot, so the trace has to be installed before Ruby
loads anything.

```bash
cd ~/code/fms

DISABLE_SPRING=1 \
DISABLE_SPRING_BOOT=1 \
RAILS_ENV=development \
SNAPSHOT_LABEL=main-eager \
SNAPSHOT_OUT="$HOME/code/fms-cross-branch-scripts/runtime-snapshot/snapshots/main-eager.json" \
RUBYOPT="-r$HOME/code/fms-cross-branch-scripts/runtime-snapshot/script/preboot_trace.rb" \
  bin/rails runner \
  "$HOME/code/fms-cross-branch-scripts/runtime-snapshot/script/dump_runtime_snapshot.rb"
```

Omit `SNAPSHOT_OUT` to write the snapshot JSON to stdout instead.

**Rename map.**

```bash
cd ~/code/fms-worktrees/zeitwerk_upgrade_low_impact

ruby "$HOME/code/fms-cross-branch-scripts/runtime-snapshot/script/dump_git_renames.rb" main HEAD \
  > "$HOME/code/fms-cross-branch-scripts/runtime-snapshot/snapshots/renames.json"
```

**Compare.**

```bash
cd ~/code/fms-cross-branch-scripts

ruby runtime-snapshot/script/compare_runtime_snapshots.rb \
  runtime-snapshot/snapshots/main-eager.json \
  runtime-snapshot/snapshots/zeitwerk-eager.json \
  --renames runtime-snapshot/snapshots/renames.json \
  --ignore  runtime-snapshot/snapshots/ignore.txt
```

The comparator takes plain file paths, so it will compare any two snapshots
regardless of where they live or what they are called.

---

## 12. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `preboot_trace_installed: false`; load-order sections empty | Spring forked a pre-booted process, or a wrapper script dropped `RUBYOPT`. The boot happened somewhere `RUBYOPT` never applied. | Confirm `DISABLE_SPRING=1` reached the process; check whether `bin/rails` or `bin/spring` re-execs. Try the raw invocation in [step 11](#11-running-without-the-wrappers). |
| `presumed_root_matched: false` | `bin/rails` was invoked from outside the application root, so the preboot hook filtered class-body events against the wrong directory. | Run from the application root — `bin/snapshot` does this for you. |
| Exit 2, "config.eager_load differs" | The two checkouts have different `config.eager_load`. | Set both to the same value and re-snapshot **both**. Editing one file does not change an already-written snapshot. |
| Exit 2, "RAILS_ENV differs" | Snapshots taken in different environments. | Re-snapshot with matching `RAILS_ENV`. |
| Exit 2, "different script versions" | One snapshot predates a change to the dumper. | Re-snapshot both sides. |
| Warning: "both snapshots were produced by script version N" | Both predate a change to the dumper, so they agree with each other while reproducing whatever the old version got wrong. | Re-snapshot both sides. |
| `constants_missing` full of namespace modules whose children are still present | Snapshots predate script version 2. Zeitwerk autovivifies an implicit namespace with `Object.const_set` from inside the gem, and a later `module Foo` reopen does not move `const_source_location`; a namespace owns no methods either, so the old dumper failed to attribute it to the app and dropped it. | Re-snapshot both sides. `Foo::Bar` cannot exist without `Foo`, so a "missing" namespace whose children survived was never a real finding. |
| `counts.constants` in the tens | The scope filter matched almost nothing. | Check `identity.root` is the real application root. |
| Large `counts.skipped` | Many classes raised during introspection. | Read the `skipped` array — it records the class name and the exception. A whole subsystem failing there would otherwise look like agreement between the branches. |
| `duplicate_names` non-empty | Two live objects claim the same constant name — the snapshot was taken after a reload cycle left a stale class on the heap. | Re-snapshot in a fresh process. The dumper picks deterministically so the output is still stable, but the pair is less trustworthy. |
| Warning: "working tree is dirty" | Uncommitted changes in a checkout. | Fine while iterating; just know the snapshot does not correspond to `identity.sha`. |
| Warning: "Bootsnap active on one side only" | One checkout has a warm cache and the other does not. | Does not affect `load_order.files` (`$LOADED_FEATURES` is populated regardless), but does affect `script_compiled` if you enabled it. |
| Huge `method_relocations`, mostly plausible-looking moves | Missing or stale rename map. | Re-run [step 3](#3-build-the-rename-map). |
| Warning: "paths are both an old and a new name" | An A→B, B→C shuffle in the rename map. Those paths are left uncanonicalized rather than rewritten inconsistently. | Usually harmless; the affected paths are listed. |
| `ancestor_diffs` full of `Generated*Methods` | You passed `--include-generated-ancestors`. | Drop the flag — they are collapsed by default for exactly this reason. |
| `ancestor_diffs` full of one module, on nearly every constant | Something is prepended or included into `Object` on one side only, so a single global fact is re-reported once per constant. `ActiveSupport::Dependencies::ZeitwerkIntegration::*` is the common one and is collapsed by default. | Add `ancestor <the module>` to the ignore list. Confirm the diagnosis first: if every row is an `add` and the label sits next to `Object` in the chain, it is a global prepend and not a per-constant finding. |
| Source diffs say "source text unavailable" | The snapshot was taken with `SNAPSHOT_SOURCE_TEXT=0`, or the sidecar is missing. | Re-snapshot with the default, or point at the sidecar with `--sources-a` / `--sources-b`. |
| Snapshot run is slow | Expected: it parses every application source file once and reflects over every method. | Nothing to do. It is already ~100x faster than the naive approach; the cost is dominated by application size. |

---

## 13. Output files

All under `runtime-snapshot/snapshots/` (gitignored).

| File | Contents |
| --- | --- |
| `<label>.json` | The snapshot. Top-level keys: `meta`, `identity`, `paths`, `load_order`, `counts`, `skipped`, `duplicate_names`, `constants`. |
| `<label>.sources.json` | Method bodies keyed by SHA-256, for the source diffs. Only methods defined under `Rails.root`. |
| `renames.json` | The old → new path map, plus the raw `git diff` records. |
| `ignore.txt` | Your triage allowlist. Not created automatically. |

The snapshot is byte-stable across runs of an unchanged checkout, so plain
`diff` works on the raw JSON — everything volatile (timestamp, hostname, pid)
is confined to the `meta` block, which the comparator ignores.

Handy inspection one-liners:

```bash
# identity and counts
ruby -rjson -e 'j=JSON.parse(File.read(ARGV[0])); puts j["identity"]; puts j["counts"]' \
  runtime-snapshot/snapshots/main-eager.json

# everything that raised during introspection
ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["skipped"]' \
  runtime-snapshot/snapshots/main-eager.json

# one constant in full
ruby -rjson -e 'puts JSON.pretty_generate(JSON.parse(File.read(ARGV[0]))["constants"][ARGV[1]])' \
  runtime-snapshot/snapshots/main-eager.json Facility

# where a class had its body opened, in order
ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))["load_order"]["class_bodies"]
  .select { |e| e["name"] == ARGV[1] }.each { |e| puts "#{e["file"]}:#{e["line"]}" }' \
  runtime-snapshot/snapshots/main-eager.json Facility

# first 40 files loaded during boot
ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["load_order"]["files"].first(40)' \
  runtime-snapshot/snapshots/main-eager.json
```
