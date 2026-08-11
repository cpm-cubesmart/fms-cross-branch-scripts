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

**Driving it from the environment.** If both checkouts read the setting from an
environment variable:

```ruby
# config/environments/development.rb
config.eager_load = ENV['EAGER_LOAD_APP'] == "true"
```

then set it per invocation instead of editing the file, and skip the hand-editing
step in [§5](#5-the-eager-pair) and [§6](#6-the-non-eager-pair):

```bash
EAGER_LOAD_APP=true  runtime-snapshot/bin/snapshot ~/code/fms main-eager
EAGER_LOAD_APP=false runtime-snapshot/bin/snapshot ~/code/fms main-noeager
```

Note that `bin/snapshot`'s eager echo greps for a literal `config.eager_load =`,
so it can only print the expression, not the value. The value that matters is
`identity.eager_load` inside the finished snapshot — read it back, or let a
driver script assert it. Deriving that assertion from the same variable you are
setting makes it worthless: four non-eager snapshots then agree with themselves
and nothing complains.

**Otherwise, the one manual step.** `config.eager_load` is set by hand in
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

Expected: `85 passed, 0 failed`.

It builds two throwaway applications in a temp directory and runs the real
dumper and comparator over them. No Rails, no database, no network, nothing
written outside `mktemp -d`. It asserts that:

- an unchanged checkout snapshots to identical bytes twice running, and
  comparing a snapshot to itself reports zero differences
- a constant that stops loading, a concern that stops being included, a
  decorator that loads before its class, and a method whose definition changes
  hands are each reported
- the rename map collapses moved-file findings to zero
- a dynamically defined accessor whose body changed **is** reported, and one
  whose body did not is **not** — bodies are digested from the compiled
  instruction sequence, so re-indenting a file, moving it, or editing a comment
  inside a method are all invisible
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
| `counts.body_digests` | within a few thousand of `counts.methods` | Near zero means no method body can be compared at all. See [troubleshooting](#12-troubleshooting). |

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
| `association_changes` | An association arrived, vanished, or changed macro/options. **Invisible to every other section** — the reader methods live in `GeneratedAssociationMethods`, which is collapsed as a timing artifact, and a reflection is not a constant, an owned method or an ancestor. A lost `has_many` silently changes what queries return and what STI code sees. |
| `class_attribute_changes` | An entry **arrived or vanished** from what an `included do ... end` block did: `__callbacks`, `_validators`, `default_scopes`, `_process_action_callbacks`. These leave the ancestor chain and the method list untouched, so **no other section can see one stop happening** — a callback that is no longer registered, a validation no longer declared, a `default_scope` composed in a different order. | Something that reaches into the class from outside it stopped running, or ran against a different set of classes. An initializer iterating `descendants` is the usual cause: classic's explicit requires had loaded them, Zeitwerk has not. |
| `resolution_order_changes` → note | Only rows where the **winning** definition changed, or the method is no longer defined at all. |
| `constant_value_changes` | A constant's value differs. Only simple values are compared; anything else records its kind and is never reported. | Load order changed which assignment ran last. |
| `resolution_order_changes` | For one method name, the ancestors defining it changed — which one wins, what `super` walks, or whether it is defined at all. **The monkey-patch section.** | A concern that stopped being included, or a `prepend` landing on the wrong side. |
| `method_set_changes` | A class does not have the same methods on both branches: one is missing (`-`), one is extra (`+`), or one has the same name and a different body (`~`). Counted per class, because that is what you act on. Bodies are compared by the digest of their **compiled instruction sequence**, so comments, formatting, file moves and namespacing do not count — only a change in what the method actually does. That is also what makes dynamically defined accessors comparable at all; they have no usable source text. | A missing method usually means the file defining it is not loaded; an extra one is often the flip side of a reopen-order change, where a definition that used to be overwritten now survives; a changed body means the wrong definition is winning. |
| `visibility_changes` | Public/protected/private changed for a method. | A `private` declaration landing in a different reopening. |
| `signature_diffs` | Parameter list differs, for methods with no comparable source hash (native/gem). | Same as above. |

### Reading a method-set row

`-` means the class stopped **defining** the method. That is not the same as the
method being uncallable, and the row says which:

```
  BaseMailer
    - BaseMailer.__callbacks   (was <gems>/…/callbacks.rb:67)
        still resolves, now inherited from #<Class:ActionMailer::Base>
```

Both are findings. A `class_attribute` writer defines the reader on the assigning
class's own singleton, so `BaseMailer` owning `__callbacks` means a callback was
registered directly on it — losing that ownership means the registration stopped
happening, even though the parent's reader still answers the call.

**`Method#inspect` cannot be used to check this.** On 2.7 it prints the receiver,
not the owner, and every `class_attribute` reader reports the same source line
whichever singleton it lives on, so an owned and an inherited method are
indistinguishable in its output. Use:

```ruby
BaseMailer.method(:__callbacks).owner
BaseMailer.singleton_class.instance_methods(false).include?(:__callbacks)
```

And check with `bin/rails runner`, not `rails console`: the console boots
differently and can show state the snapshot never had.

### Associations

Captured from `reflect_on_all_associations`, never from `reflection.klass`,
`.table_name` or anything else that constantizes — that would autoload the target
and corrupt the non-eager snapshot. Option **keys** are recorded even when the
value will not serialize, so an option arriving or vanishing is visible whatever
it holds.

### Class attribute values

A curated list, not every `class_attribute`: `_routes`, `_layout` and
`default_params` are expected to differ and would need their own triage pass.
The four captured are the ones that carry behaviour.

**Membership is graded above ordering.** A callback that stops being registered
changes what runs; one that runs at a different point in the chain usually does
not, and on a real migration there were nine reorderings against one removal.
Ordering goes to `class_attribute_order_only` so the removal is visible. The same
rule governs method resolution: a changed winner is semantic, a change only below
the winner is not.

Values are digested from a canonical structure rather than `inspect` — a callback
chain reduces to its ordered filter names, so the live chain objects never enter
the digest. A filter that is not a symbol (a proc, a callable object) is recorded
by class, never by identity, or it would churn every run. Anything that will not
serialize cleanly records its kind and no digest, and is never reported as
changed.

Rows name the module that defines each filter, which is what turns "something
moved" into "this module's include point moved" — the thing you actually go and
change. Resolved from the ancestor data already in the snapshot:

```
  Facility.__callbacks
    commit: update_glli_display_codes  5 -> 0   (defined by GlliDisplayable)
```

The row prints the affected chain, so the difference is readable without going
back to the application:

```
  BaseMailer.__callbacks
     main-eager:     process_action: [set_locale, log_delivery]
     zeitwerk-eager: process_action: []
```

### Constant values

Only simple values are digested — strings, symbols, numbers, booleans, `nil`, and
arrays/hashes/sets of those. Anything else records its kind and is never reported
as changed, because its `inspect` is not stable enough to trust.

String values that are absolute paths are normalized the same way every file path
in the snapshot is, so a constant built from `Rails.root.join(...)` does not
differ merely because the two checkouts sit at different paths. That one omission
accounted for 15 of the first 17 differences this section ever reported.

### Reading a resolution-order row

```
  #fetch_setting   6 classes
       (not defined)
    => Setting
       e.g. ClientApplicationSettings, CompanySettings, RoleSettings
```

For one method name, the ancestors that define it in the order Ruby consults
them. The **first entry wins the call**; the rest are what `super` walks.
`(not defined)` means no ancestor defined it on that side at all.

Rows are grouped by the change itself, not by class, because a change inherited
from a shared ancestor is one fact — `Object` gaining `#require` under Zeitwerk
is a single row across 3,606 classes rather than 3,606 rows. The count is how
many classes see it, and the examples are three of them.

**A chain that merely reordered is not reported.** Only a change to one of these
lists is. That is the whole point: on this application, `Decoratable` moving
fourteen positions in every model produced 626 rows and changed no method's
resolution, and it now produces nothing.

The one thing this does *not* cover is `included do ... end` side effects —
callback registration order, `default_scope` composition, validations — which
depend on include order without any method's owner list changing. Those are not
in the snapshot at all.

### Anonymous modules

Plenty of chain members have no name — `Module.new` mixins, and the modules Rails
generates per class for `store_accessor`. They are labelled by the constant that
owns them plus the file their methods come from:

```
#<anonymous module of InsurancePlanChangeImportBatch @ <gems>/…/store.rb>
```

The owner is the **most specific** constant whose chain contains the module, not
necessarily the only one. The origin file alone is not an identity: 258 classes
in this application have a distinct `store_accessor` module, all defined by
`define_method` inside `active_record/store.rb`.

### Why reopen order is not its own section

A class opened by several files is normal in a namespaced application, and if the
end state matches it is not a finding. It is still the usual *explanation* for one
— which file's definition ran last — so it is attached to classes that do have a
finding:

```
  Widget
    ~ Widget#price  (lib/decorator.rb:2 -> app/store/widget.rb:13)
      opened by main: app/widget.rb -> lib/decorator.rb
      opened by zeitwerk: lib/decorator.rb -> app/store/widget.rb
```

Read that as: on Zeitwerk the patch is applied *first* and then overwritten by the
original definition. No error is raised. The method silently reverts.

### Informational sections

| Section | Meaning |
| --- | --- |
| `class_attribute_order_only` | Same callbacks/validators, different order. `after_commit` runs in registration order so this *can* matter, but it is normally one module being included at a different point, and it is an order of magnitude more common than a real removal. |
| `attribute_ownership_only` | A `class_attribute` reader stopped or started being defined on a class's own singleton, while the value it resolves to is **byte-identical** on both branches — an assignment that wrote back the inherited value creates ownership and nothing else. Suppressed from the semantic sections only when both sides captured a comparable value and the two are equal; any difference at all, or a missing capture, leaves the row in `class_attribute_changes` or `method_set_changes`. |
| `resolution_super_only` | The same definition still wins the call; only what `super` walks moved. Inert unless the winner calls `super`. |
| `files_only_a` / `files_only_b` | A file was loaded on one branch only, judged by the union of `$LOADED_FEATURES`, the class-body trace, and classic's `Dependencies.history` — no single one of those is comparable across autoloaders. Worth scanning — a file in `files_only_a` often explains a `constants_missing` entry. |

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
file     vendor/**/*            # ignore a file in the load-set/load-order sections
method   Widget#price           # instance method
method   Widget.build           # singleton method (note the dot)
section  files_only_b           # ignore a whole section
```

Section ids are exactly the names printed in the counts header. An ignored
section still prints its count, marked `(ignored)`, and is excluded from the
semantic total.

`constant` is the broadest rule: ignoring a constant suppresses its ancestors,
methods, source and reopen-order findings too.

`constant` and `ancestor` are not the same axis. `constant` matches the chain
*owner* — the thing the row is reported against. `ancestor` matches a chain
*member*, striking that module out of every chain on both sides; a constant whose
only difference was that module then drops out of the resolution-order section, while
constants with a genuine difference keep their row minus the noise line. Reach for
`ancestor` when one module is prepended or included into `Object` on one side, so a
single global fact gets re-reported once per constant. Glob patterns cross `::`.

The report tells you when a rule did not take. A rule that fails to parse, and a
rule that matched nothing on this pair, are both warnings in the header:

```
!  warning: ignore list: line 7: unknown rule kind "constnat" (expected constant, ...)
!  warning: ignore list: 1 rule(s) matched nothing: constant Nonexistent::Thing
```

An unused rule is not necessarily wrong — one ignore list covering several pairs
will always carry rules that do not apply to all of them — but it is usually
either a typo or an entry left behind after the underlying issue was fixed.

A `#` opens a comment at the start of a line or after whitespace, so the
inline-comment style above works. It is *not* a comment mid-token, which keeps
`method Widget#price` intact, and *not* when followed by `<`, which is what makes
`ancestor #<anonymous module of Solo*` writable.

`file` patterns are matched with `FNM_PATHNAME`, so `*` does not cross `/`. A
trailing `/**` would mean one directory level only, which is never the intent, so
`vendor/**` is rewritten to `vendor/**/*`; write `vendor/*` if you really want one
level. `constant`, `ancestor` and `method` globs are matched without that flag, so
`*` crosses `::` freely.

> Record **why** next to each entry. Six weeks from now the comment is the only
> thing left explaining the decision.

---

## 10. Option reference

### `bin/snapshot <app-dir> <label>`

| Variable | Default | Effect |
| --- | --- | --- |
| `RAILS_ENV` | `development` | Environment to boot. |
| `SNAPSHOT_DIR` | `runtime-snapshot/snapshots` | Where snapshots are written. |
| `SNAPSHOT_SOURCE_TEXT` | `1` | `0` skips capturing method bodies. The report no longer prints source, so this only costs you the ability to inspect a body by hand from the sidecar. |
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
| `--include-generated-ancestors` | Keep Rails' `Generated{Attribute,Association}Methods` in ancestor chains. Collapsed by default, because whether ActiveRecord has generated them yet is a timing artifact rather than a load-order fact. |
| `--include-autoloader-shims` | Keep the `load` / `require` / `const_missing` resolution rows that `Dependencies.unhook!` produces. Collapsed by default: turning classic autoloading off is implemented by defining those methods directly on `Object` and `Module` to shadow the classic hooks, which every class in the application then sees. |
| `--include-zeitwerk-shims` | Keep `ActiveSupport::Dependencies::ZeitwerkIntegration::*` in ancestor chains. Collapsed by default: `take_over` does `Object.prepend(RequireDependency)`, so on the zeitwerk side it appears in every `Object`-descended chain and every singleton chain — one mode-switch fact re-reported once per constant, and the mode is already asserted from `identity`. |
| `--renames PATH` | Override the auto-detected rename map. |
| `--ignore PATH` | Override the auto-detected ignore list. |
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
| Warning: "paths are both an old and a new name" | An A→B, B→C shuffle in the rename map. Those paths are left uncanonicalized rather than rewritten inconsistently. | Usually harmless; the affected paths are listed. |
| `load` / `require` / `const_missing` resolution changed | `ActiveSupport::Dependencies.unhook!`. It cannot un-include a module, so it shadows the classic hooks by defining the originals directly on `Object` and `Module`. Collapsed by default; `--include-autoloader-shims` shows them. | Expected — it *is* the mode switch. But note that `const_missing` reverting to stock is what removes classic's autoload-on-missing-constant hook: code that relied on it now raises `NameError` at runtime, which this report cannot see. |
| A resolution-order row spans thousands of classes | One global fact — `Object` gains `#require`/`#load` and `Module` gains `#const_missing` under Zeitwerk, so every class sees it. | Expected. Ignore-list them once with `method *#require` and friends. |
| Every `~` row says `no method list for: …` | Snapshots predate script version 3, so there are no method names to classify against and every reorder stays semantic. | Re-snapshot both sides. |
| A `~` or `-` names an anonymous module you cannot identify | Expected — it has no name. | Read the `provides:` line under it, and the `of <Constant>` in the label. If the label has no `of` part, the snapshot predates script version 4; re-snapshot. |
| A `~` row names a method neither branch touched | Snapshots predate script version 6, when bodies were still compared by source text located through `source_location`. For a metaprogrammed method that points at the line which generated it, so an `include` or a `has_many` sitting at the wrong line number read as a changed body — two thirds of them in a real run. | Re-snapshot both sides. |
| A dynamically defined accessor changed and nothing was reported | Snapshots predate script version 6. Those methods have no usable source text, so before bodies were digested from the instruction sequence they had no digest at all — 13% of every method in the application, including all 626 of `FacilitySettings`'. | Re-snapshot both sides. |
| `counts.body_digests` is near zero | `RubyVM::InstructionSequence.of` returned nothing usable, so no body can be compared and every `~` row is missing. Most likely Bootsnap serving instruction sequences from its binary cache. | Re-snapshot with `DISABLE_BOOTSNAP=1`. Compare `counts.body_digests` against `counts.methods` — they should be within a few thousand of each other, the gap being gem and native methods. |
| `files_only_b` in the thousands with no constant difference | The two sides were measured by different mechanisms. Classic loads app files with `Kernel#load`, which never enters `$LOADED_FEATURES`; Zeitwerk uses `require`, which does. | Snapshots predate script version 12. Re-snapshot; the comparison then unions in classic's own load record. |
| `files_only_a` roughly equal to `counts.autoloaded` | Every entry in classic's load record became an orphan row. `require_or_load` chomps `.rb` before expanding, so `history` holds extension-less paths while the other two signals hold real filenames. | Fixed in the comparator, which restores the extension before applying the rename map. If it recurs, check `with_extension` still runs ahead of `canonical_path`. |
| Warning: "classic autoloader, but no ActiveSupport::Dependencies.history" | That leg of the union is missing, so a file that only monkey-patches — no class body, loaded via `load` — is invisible on the classic side. | Re-snapshot with script version 12+. Check `counts.autoloaded` is non-zero on the classic snapshot. |
| Added an ignore rule and the count did not move | The rule did not parse, or it parsed but matched nothing. | Read the `ignore list:` warnings in the header — both cases are reported there with a line number. A `file` rule needs the path exactly as the report prints it, canonicalized through the rename map. |
| Snapshot run is slow | Expected: it parses every application source file once and reflects over every method. | Nothing to do. It is already ~100x faster than the naive approach; the cost is dominated by application size. |

---

## 13. Output files

All under `runtime-snapshot/snapshots/` (gitignored).

| File | Contents |
| --- | --- |
| `<label>.json` | The snapshot. Top-level keys: `meta`, `identity`, `paths`, `load_order`, `counts`, `skipped`, `duplicate_names`, `ancestor_methods`, `constants`. Each constant carries `ancestors`, `values` (simple constant values, digested), `class_attributes`, and `methods`. |
| `<label>.sources.json` | Method bodies keyed by SHA-256. Nothing in the report reads these — they are there so you can pull up a body by hand when a `~` row is surprising. Only methods defined under `Rails.root`. |
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
