# Cross-branch scripts

Scripts for comparing the runtime behavior of two branches of a Rails
application. Written for CubeSmart's FMS app during its classic-autoloader →
Zeitwerk migration, where the risk is that a class quietly stops being loaded,
a concern stops being included, or a monkey patch lands in a different order —
none of which necessarily raises an error.

| Directory | What it does |
| --- | --- |
| `runtime-snapshot/` | Captures and diffs the full runtime state of a booted app: load order, constants, ancestors, methods, method source. **Start here.** |
| `facility-settings/` | Behavioral spot-check: reads Facility/Company settings both ways and prints them for eyeballing. |
| `source-trace/` | Minimal `TracePoint(:line)` trace of which app files execute during boot + eager load. |

---

# runtime-snapshot

## The problem

Under the classic autoloader, `config/application.rb` explicitly `require`s a
large number of files. Under Zeitwerk those requires go away, and the same
constants have to arrive some other way — autoloading, eager loading, or
`to_prepare` blocks in `config/initializers`.

You need to know that the runtime state ends up the same. Not "the app boots" —
the same classes, with the same ancestors in the same order, with the same
methods, resolving to the same source.

## The workflow

This is a convergence loop, not a one-shot report:

1. Snapshot the classic branch.
2. Snapshot the Zeitwerk branch.
3. Compare. The report is a worklist.
4. Fix something on the Zeitwerk branch (usually a `to_prepare` block).
5. Re-snapshot **just the Zeitwerk branch** and compare again.
6. Repeat until the semantic counts are zero.

The counts header exists so step 6 is a glance, not a read.

## How to run it

**→ [`runtime-snapshot/RUNBOOK.md`](runtime-snapshot/RUNBOOK.md)**

The runbook is the operating manual: the full command sequence, what to verify
before trusting the first diff, what every section of the report means, the
complete option and environment-variable reference, how to run the scripts
without the wrappers, and a troubleshooting table.

The short version, once you have read it:

```bash
cd ~/code/fms-cross-branch-scripts

runtime-snapshot/test/selftest.sh                                              # once
runtime-snapshot/bin/renames  ~/code/fms-worktrees/zeitwerk_upgrade_low_impact main

# set config.eager_load to the same value in BOTH checkouts' development.rb, then:
runtime-snapshot/bin/snapshot ~/code/fms                                       main-eager
runtime-snapshot/bin/snapshot ~/code/fms-worktrees/zeitwerk_upgrade_low_impact zeitwerk-eager
runtime-snapshot/bin/compare  main-eager zeitwerk-eager
```

`config.eager_load` is deliberately *not* set by the tooling. Setting it by hand
gives a true boot-time eager load, with initializers, `to_prepare` hooks and
classic's explicit requires interleaving exactly as they do in a real boot.
Forcing `Rails.application.eager_load!` from inside the runner would be more
convenient and less faithful.

## How it works

| File | Role |
| --- | --- |
| `script/preboot_trace.rb` | `RUBYOPT` preload. Baselines `$LOADED_FEATURES` and installs a `TracePoint(:class)` **before** the app boots. |
| `script/dump_runtime_snapshot.rb` | `rails runner` script. Walks `ObjectSpace`, writes the snapshot JSON plus a `.sources.json` sidecar of method bodies. |
| `script/compare_runtime_snapshots.rb` | Diffs two snapshots, applies the rename map, prints the report. |
| `script/dump_git_renames.rb` | Builds the old → new path map from `git diff --name-status -M`. |
| `script/find_load_cycles.rb` | Takes one snapshot and reports files that were read while still loading. |
| `test/selftest.sh` | End-to-end test of all of the above against generated fixtures. |
| `RUNBOOK.md` | How to actually run it. |
| `ignore.example.txt` | Template for the triage allowlist. |

Four design decisions worth knowing about, because they are the difference
between a useful report and a wall of noise:

**The pre-boot hook.** `bin/rails runner` executes its script *after* boot
finishes, so a `TracePoint` installed there misses the entire window of
interest. The `RUBYOPT` preload runs before Bundler, before `config/boot.rb`,
before `config/application.rb`.

**Three signals for the load set, because no one of them works on both
branches.** `$LOADED_FEATURES` is append-ordered by the VM and survives Bootsnap's
instruction-sequence cache — but classic autoloading loads application files with
`Kernel#load`, which never registers there, so on the classic branch it is missing
essentially the whole application. Comparing it alone reported 3,747 files as
"Zeitwerk only" when 99% of them had demonstrably executed on both.

The preboot `TracePoint(:class)` sees anything that runs a `class` or `module`
body however it was loaded, but is blind to a file that only does
`Foo.class_eval { ... }`. `ActiveSupport::Dependencies.history` is classic's own
record of what it `require_or_load`ed, and is the only signal that sees that last
category on the classic side. The comparison uses the union of all three — after
restoring the `.rb` that `require_or_load` chomps, or every autoloaded file would
appear on the classic side under a name the others never use.

A `:script_compiled` trace is available via `SNAPSHOT_TRACE_COMPILE=1` but is
defeated by a warm Bootsnap cache.

**Nothing is ever `constantize`d.** Constants are enumerated through
`ObjectSpace`, never by resolving names. In non-eager mode the whole point is to
observe what boot alone loaded; a snapshot that triggers autoloads while looking
at them is measuring itself. (`Module.const_source_location`, which the dumper
does call, was verified not to resolve pending autoloads.)

**The report answers five questions and nothing else:** which classes are not
loaded on one side, which method name now resolves to a different definition,
which method bodies changed, which constant values changed, and which classes
gained or lost methods. Sections that described the *mechanism* rather than the
outcome — reopen order, whole-chain ancestor reordering, line-number moves, load
order — were removed, because on a real migration they outnumbered the findings
by two orders of magnitude.

**Method bodies are compared by their compiled instruction sequence, not by
source text.** Locating source through `source_location` is unreliable for
anything metaprogrammed: for a `define_method` accessor it points at the line
that generated the method, so the text there is unrelated — or, as with all 626
of `FacilitySettings`' generated accessors, there is nothing usable at all and a
real change is invisible. That was 13% of every method in the application.

`RubyVM::InstructionSequence.of` has neither problem, and normalizing away
bytecode offsets, line annotations, file paths and enclosing-scope labels leaves
a digest that is stable across the two edits this migration makes constantly:
moving a file, and wrapping a top-level class in a module namespace. Comments and
formatting stop counting too, which is correct for "does this method behave
differently". The source text is still captured to a sidecar, for reading by hand
when a reported change is surprising.

**Re-entrant loads are found separately, from a single snapshot.** The comparison
answers "do the two branches differ"; `bin/cycles` answers "was any file read
while it was still being written". That failure has no error, no exception and no
missing constant — on this application it silently cost one class all 622 of its
generated accessors, because a macro in a class body iterated a hash that the file
still loading above it had not finished populating. The snapshot already records
the two orderings needed to detect it (a class-body trace for starts,
`$LOADED_FEATURES` and `Dependencies.history` for completions), so no extra
instrumentation was required. See [RUNBOOK section 14](runtime-snapshot/RUNBOOK.md#14-finding-re-entrant-loads).

## Scope

The snapshot covers constants defined under `Rails.root`, plus any gem or core
class that application code reopens — the monkey patches whose load order this
migration puts at risk — plus the namespaces those constants are nested in.
That last clause is not redundant: Zeitwerk autovivifies an implicit namespace
with `Object.const_set` from inside the gem, and a pure namespace owns no
methods, so `AbacusHealth` would otherwise look like gem code and drop out on
one branch only.

Gem internals the app never touches are out of scope; they still appear by name
inside ancestor chains and as method owners, so a concern being prepended in a
different order is still caught.

---

# facility-settings

Behavioral spot-check for the FMS settings lookup: loads Facility 725 and the
CubeSmart Company, then prints every settings key via both the method lookup and
the raw hash so the two branches can be diffed directly.

```bash
cd ~/code/fms
DISABLE_SPRING=1 bin/rails runner ../fms-cross-branch-scripts/facility-settings/script/settings.rb \
  > /tmp/main-settings.txt

cd ~/code/fms-worktrees/zeitwerk_upgrade_low_impact
DISABLE_SPRING=1 bin/rails runner ../../fms-cross-branch-scripts/facility-settings/script/settings.rb \
  > /tmp/zeitwerk-settings.txt

diff -u /tmp/main-settings.txt /tmp/zeitwerk-settings.txt
```

Set the same `config.eager_load` value in both checkouts first, and expect
`RAILS_ROOT` and object addresses to differ in the diff.

`script/settings-debug.rb` is the same idea narrowed to a single key with a
`binding.pry` in the lookup path.

---

# source-trace

Enables `TracePoint(:line)` and reports the first line executed in each file
under the project root, in order, during boot and eager load. Run it directly
rather than through `bin/rails runner`, since it has to install the trace before
loading the environment:

```bash
cd ~/code/fms
DISABLE_SPRING=1 bundle exec ruby ../fms-cross-branch-scripts/source-trace/script/source_code_execution_trace.rb
```

`:line` tracing is slow on a large app. For file ordering,
`runtime-snapshot`'s `load_order` is cheaper and survives Bootsnap; reach for
this when you need to see execution reaching a specific line rather than just
which files loaded.
