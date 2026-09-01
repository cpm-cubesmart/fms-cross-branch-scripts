# Snapshot data dictionary

Every field a snapshot captures, where it comes from, and what reads it.

A snapshot is one JSON file written by `script/dump_runtime_snapshot.rb` during a
single Rails boot. It is the only artifact the reports read: the comparison
report (`script/compare_runtime_snapshots.rb`, via `bin/compare`) and the
re-entrant load report (`script/find_load_cycles.rb`, via `bin/cycles`) both work
entirely from snapshots on disk, never from a checkout.

Two properties shape everything below:

- **The dumper never triggers an autoload.** `constant_values` skips pending
  autoloads, `Module.const_source_location` does not resolve them, and the
  autoload registry is read from plain arrays. This is the one invariant the
  script cannot break — anything that loaded a constant would corrupt the
  non-eager snapshot it exists to measure.
- **The snapshot is byte-stable.** Two runs of an unchanged checkout produce
  identical bytes, so plain `diff` works on the raw JSON. Everything volatile is
  confined to `meta`, which no report reads.

This document says *what feeds* a report section. For what a non-zero count
*means* and how to fix it, see [RUNBOOK §8](RUNBOOK.md#8-reading-the-report). The
snake_case ids in the **Used by** columns are the same token throughout: the key
in the counts block, the leading word of the section's `##` heading, the key in
`--format json`, and what a `section` rule in the ignore file takes.

## Top-level shape

| Key | Holds | Read by |
| --- | --- | --- |
| `meta` | When and where this snapshot was taken | nothing |
| `identity` | What was booted — the pair guard | header, errors, warnings |
| `paths` | Rails' configured autoload/eager-load paths | nothing |
| `load_order` | What happened, in the order it happened | file sections; both cycles clocks |
| `autoload_registry` | What each autoloader considers its own | `autoload_managed_only_*` |
| `counts` | Sizes, for the stability check | one warning |
| `skipped` | Constants that raised during introspection | nothing |
| `duplicate_names` | Names claimed by two live objects | nothing |
| `ancestor_methods` | Method names owned by every chain member | resolution sections |
| `constants` | The inventory — one record per constant in scope | most sections |

---

## `meta`

Written so the file can be identified after the fact, and quarantined here so the
rest of the snapshot stays byte-comparable.

| Field | What it holds | Captured from | Used by |
| --- | --- | --- | --- |
| `generated_at` | UTC ISO-8601 timestamp | `Time.now.utc.iso8601` | nothing |
| `hostname` | Machine that booted | `Socket.gethostname` | nothing |
| `pid` | Process that booted | `Process.pid` | nothing |

## `identity`

The pair guard. The comparator refuses a pair it cannot trust, and warns about a
pair it can only partly trust — so most of this block exists to be checked rather
than reported.

| Field | What it holds | Captured from | Used by |
| --- | --- | --- | --- |
| `label` | The name of this side | `SNAPSHOT_LABEL` (falls back to the filename) | Names A and B in the header, in every warning, and in section titles. Survives `--anonymize`: without it the two sides are indistinguishable. Also titles the cycles report |
| `rails_env` | `Rails.env` | Rails | **Error** if the two differ. Printed in the header's `mode:` line |
| `eager_load` | `config.eager_load` | Rails | **Error** if the two differ — an eager snapshot against a non-eager one measures the mode, not the branch. Printed in `mode:` |
| `autoloader` | `config.autoloader` as a string | Rails | nothing |
| `zeitwerk_enabled` | `Rails.autoloaders.zeitwerk_enabled?` | Rails, feature-detected | Gates the "classic autoloader, but no `Dependencies.history`" warning — that check only applies to a classic side |
| `rails_version` | `Rails.version` | Rails | nothing |
| `ruby_version` | `RUBY_VERSION` | Ruby | nothing |
| `root` | Absolute `Rails.root` | Rails | nothing. Every path in the snapshot is already normalized relative to it. Note it is here whatever `--anonymize` is set to — the flag governs terminal and report output, not the file |
| `branch` | Current branch | `git rev-parse --abbrev-ref HEAD` | Header only, suppressed by `--anonymize` |
| `sha` | Current commit | `git rev-parse HEAD` | Header only (first 10 chars), suppressed by `--anonymize` |
| `dirty` | Working tree has changes | `git status --porcelain` non-empty; `nil` if not a repo | **Warning** per side. `nil` and `false` are kept distinct — conflating them makes every clean checkout report itself dirty |
| `bootsnap_active` | `defined?(Bootsnap)` | Ruby | **Warning** when the two sides differ |
| `preboot_trace_installed` | The `RUBYOPT` hook ran | `preboot_trace.rb` | **Warning** when false: `load_order.class_bodies` is empty, so the load-order sections have nothing to say |
| `presumed_root_matched` | The hook's guessed root equalled `Rails.root` | comparison at dump time | **Warning** when false: class-body data is incomplete |
| `script_version` | Dumper version (currently 15) | `SCRIPT_VERSION` | **Error** when the two differ. **Warning** when both are older than the comparator's `EXPECTED_SCRIPT_VERSION` — two equally stale snapshots would otherwise compare cleanly and reproduce whatever the old dumper got wrong |
| `capture_sources` | Whether the sidecar was written | `SNAPSHOT_SOURCE_TEXT` | nothing |

## `paths`

Rails' configured load paths, normalized relative to `Rails.root` and sorted.
Captured for diagnosis by hand — a `constants_missing` list that is really a
missing eager-load path shows up here — but **no report reads any of the three**.

| Field | Captured from |
| --- | --- |
| `autoload_paths` | `config.autoload_paths` |
| `eager_load_paths` | `config.eager_load_paths` |
| `autoload_once_paths` | `config.autoload_once_paths` |

## `load_order`

What happened during the boot, in the order it happened. The three populated
lists are used two completely different ways: the comparison report **unions**
them into one file set, and the cycles report treats them as **clocks**.

| Field | What it holds | Captured from | Used by |
| --- | --- | --- | --- |
| `files` | Files that entered `$LOADED_FEATURES` during the boot window, normalized. Append-ordered by the VM, which is what survives Bootsnap's iseq cache and autoload-triggered requires | `$LOADED_FEATURES` minus the pre-boot baseline and the preload script's own requires | `files_only_a` / `files_only_b` (unioned); the `$LOADED_FEATURES` completion clock in the cycles report |
| `autoloaded` | Classic's own `require_or_load` record. **Deliberately unsorted** — it is the only ordering signal the classic side has | `ActiveSupport::Dependencies.history` | `files_only_a` / `files_only_b` (unioned); the `Dependencies.history` completion clock. A list over 100 entries that is exactly sorted is **refused** as a clock rather than ranked — it was stored sorted through script version 12, and ranking it turned every alphabetical accident into a nesting claim |
| `class_bodies[]` | One event per `class` or `module` keyword that executed | `:class` TracePoint installed by `preboot_trace.rb` before Rails boots | see below |
| `script_compiled[]` | Files compiled, when `SNAPSHOT_TRACE_COMPILE=1`. Empty otherwise, and only meaningful with a cold Bootsnap cache | `:script_compiled` TracePoint | nothing |
| `dropped_class_events` | How many class events the trace discarded (buffer cap), or `null` with no trace | the preboot hook's counter | nothing |

### `load_order.class_bodies[]`

| Field | What it holds | Used by |
| --- | --- | --- |
| `name` | Constant whose body opened, anonymous modules normalized | `definition_sites` → the `opened by` context line attached to a `method_set_changes` row. Reopen order is not a section of its own — it is normal in a namespaced app and only matters through the method-set change it causes |
| `file` | Normalized path of the file that opened it | `files_only_a` / `files_only_b`; the cycles report's **start clock** (first index at which each file appears) |
| `kind` | `class` or `module` | nothing |
| `line` | Line the body opened on | nothing |

Why three file signals rather than one: no single one sees a load on both
branches. `$LOADED_FEATURES` misses essentially the whole application on the
classic side, because classic autoloads with `Kernel#load`, which never registers
there. `class_bodies` sees anything that executed a class keyword however it was
loaded, but is blind to a file that only does `Foo.class_eval { ... }`.
`autoloaded` is the only signal that catches that last category on the classic
side. Comparing any one of them compares the autoloader rather than the
application: on this migration `$LOADED_FEATURES` alone called 3,747 files
"zeitwerk only" while 99% of them had demonstrably executed on main.

## `autoload_registry`

Which constants each autoloader considers its own — the only place either
autoloader says that. `constants` records that a constant exists and where it was
defined, never who is responsible for unloading it.

| Field | Source | Order |
| --- | --- | --- |
| `autoloaded_constants` | `ActiveSupport::Dependencies.autoloaded_constants` — what classic's `const_missing` actually resolved. An event record | resolution order, unsorted |
| `unloadable_main` | `Rails.autoloaders.main.unloadable_cpaths` — everything Zeitwerk registered an autoload for, loaded or not. A registry | sorted |
| `unloadable_once` | `Rails.autoloaders.once.unloadable_cpaths` | sorted |

All three feed `autoload_managed_only_a` / `autoload_managed_only_b`. The
comparator **unions the three per snapshot** and diffs the two sets, rather than
pairing list against list: only one is ever populated on a given branch, so the
union is classic's record diffed against Zeitwerk's registry — and it stays
correct for a same-branch noise-floor run, where pairing by list name would diff
a populated list against an empty one and report the whole application.

All three go empty when reloading is off, which is a statement about the mode and
not about the application; the comparator warns rather than reporting a clean
empty comparison. See [RUNBOOK §13](RUNBOOK.md#13-output-files) for the same
table with the counts each one feeds.

## `counts`

Sizes, computed at dump time. These exist for the stability check in
[RUNBOOK §4](RUNBOOK.md#4-prove-the-snapshot-is-stable) and for eyeballing a
snapshot before trusting it — a `constants` count in the tens means the scope
filter found almost no application code. **Only one is read by a report**:
`counts.autoloaded`, which gates the "classic autoloader, but no
`Dependencies.history` was captured" warning.

| Field | Counts |
| --- | --- |
| `constants` | Records in `constants` |
| `methods` | Method records across every constant |
| `body_digests` | Methods that produced an iseq digest. Near zero means no body can be compared at all |
| `loaded_files` | `load_order.files` |
| `autoloaded` | `load_order.autoloaded` — **read**, see above |
| `autoloaded_constants` | `autoload_registry.autoloaded_constants` |
| `unloadable_main` | `autoload_registry.unloadable_main` |
| `unloadable_once` | `autoload_registry.unloadable_once` |
| `class_bodies` | `load_order.class_bodies` |
| `skipped` | `skipped` |
| `duplicate_names` | `duplicate_names` |
| `ancestor_modules` | Distinct labels in `ancestor_methods` |

## `skipped` and `duplicate_names`

The two "this snapshot may not be trustworthy" lists. Neither is read by any
report; both are there to be looked at when a comparison surprises you.

| Key | Shape | What it means |
| --- | --- | --- |
| `skipped[]` | `{ "name", "error" }`, sorted by name | A constant raised during introspection and is absent from `constants`. A hostile `name`, `==` or `ancestors` override is the usual cause — the dumper reflects through unbound methods precisely so one of these cannot corrupt the rest |
| `duplicate_names[]` | Constant names, sorted and unique | Two live objects claimed the same constant name, almost always a stale copy left behind by a reload. The dumper keeps the one with the lower `digests.all` so the file stays deterministic; a non-empty list means the snapshot was taken against a reloaded process |

## `ancestor_methods`

`{ label => [method name, ...] }` — the instance methods owned by every module
that appears in any ancestor chain, deduplicated globally so a module mixed into
4,000 chains is stored once. Labels match the strings in `constants[].ancestors`
and `constants[].singleton_ancestors`.

This exists to answer the only question that makes a chain reordering matter for
dispatch: did the module that moved cross anything defining the same method name?
That cannot be answered from `constants` alone — chains reference roughly twice
as many modules as are in scope, and the gem mixins in every ActiveRecord chain
own no application code, so they are never captured as constants.

Read per branch and **never unioned**: which methods a chain member owns is
exactly what can differ. The comparator derives `CHANGED_OWNERS` — labels whose
method set differs between the branches — and feeds it into
`resolution_order_changes` and `resolution_super_only`. Filtering on "the chain
moved" alone missed 2,980 of 3,606 affected constants; an ancestor that merely
*gained* a method is how "Object now defines `#require`" surfaces.

One rule covers both chains: what a member contributes is its **own** instance
methods. In a singleton chain the members are singleton classes and extended
modules, whose instance methods are exactly what dispatches there.

## `constants`

`{ constant name => record }`, sorted. A constant is in scope if it is defined
under `Rails.root`, **or** if any method it owns is — the second clause is what
pulls in the gem and stdlib classes application code reopens, whose load order is
precisely what this migration puts at risk. Rails' synthesised
`GeneratedAttributeMethods` / `GeneratedAssociationMethods` are excluded, and
implicit namespaces are added back in a closure pass so Zeitwerk's autovivified
modules do not read as "no longer loaded".

### Identity

| Field | What it holds | Captured from | Used by |
| --- | --- | --- | --- |
| `kind` | `class` or `module` | `Module`/`Class` test through an unbound method | The cycles report, to describe a constant. Not read by the comparator |
| `origin` | `app` or `reopened_gem` | `app` when the definition site is under `Rails.root` or there is no site at all; `reopened_gem` when it is defined in C or a gem but owns application methods | Row text in `constants_missing` and `constants_extra` |
| `superclass` | Parent class label, `null` for a module | `Class#superclass` through an unbound method | `superclass_changes` — the whole section |
| `const_file` | Normalized definition path, `<native>` for a C-defined constant, `null` when there is no site | `Module.const_source_location`, which does **not** resolve pending autoloads | Row text in `constants_missing` / `constants_extra`; the cycles report's file-of-constant map |
| `const_line` | Line of that site | same | Row text in the same two sections |

### Chains

| Field | What it holds | Used by |
| --- | --- | --- |
| `ancestors[]` | The full ancestor chain as labels, in order | `resolution_order_changes`, `resolution_super_only` — walked per method name against `ancestor_methods` to find which definition wins and what `super` reaches. Chosen for instance methods |
| `singleton_ancestors[]` | The singleton class's chain, `null` if unavailable | The same two sections for singleton methods, and `attribute_ownership_only` |

Anonymous modules get a synthesised stable label rather than an object address.
Three families of chain member are collapsed by default and restorable by flag:
Rails' generated method modules (`--include-generated-ancestors`), the classic
autoloader shims (`--include-autoloader-shims`), and Zeitwerk's integration
modules (`--include-zeitwerk-shims`).

### `values` — simple constant values

`{ constant name => entry }` for constants held *inside* this one. Modules and
classes are skipped, since they are captured as records in their own right, and
**pending autoloads are skipped** — reading one would load it.

| Field | What it holds | Used by |
| --- | --- | --- |
| `kind` | Value's type name | Printed on the row; the only thing reported when a value will not serialize |
| `sha` | SHA-256 of the canonical serialization, with **hash pairs sorted** | `constant_value_changes` when the two differ |
| `order_sha` | SHA-256 keeping insertion order. Recorded **only when it differs from `sha`** — otherwise every constant would carry a duplicate digest | `constant_value_order_only`. Its absence means order and content already agree, so the comparator falls back to `sha` |

So `sha` answers "same keys, same values" and `order_sha` answers "in the same
order". A hash that merely reordered lands in the informational section, not the
semantic one — Ruby preserves hash order so `#each` sees it, but a hash built by
iterating something that follows load order reorders for reasons unrelated to
behaviour.

### `class_attributes` — what `included do ... end` did

`{ attribute name => entry }` over a fixed list (`__callbacks`, `_validators`,
`default_scopes`, `_process_action_callbacks` and friends). Read-only, through an
unbound reflector so a hostile class cannot lie, and no reader is ever defined.

| Field | What it holds | Used by |
| --- | --- | --- |
| `kind` | The value's type name | Printed on the row |
| `chains` | `{ chain name => [filter, ...] }` — structured, not a formatted string, so the comparator can say "one filter moved" rather than printing two near-identical blobs. A `Symbol`/`String` filter is its own name; anything else is `<ClassName>`. Capped at 400 entries per chain | `class_attribute_changes` when membership changed, `class_attribute_order_only` when only the order did, and `attribute_ownership_only` via `inert_class_attribute?` — a reader that stopped being owned while the value it resolves to is byte-identical |

These are the section that nothing else can see: registering a callback,
composing a `default_scope` and declaring a validation all leave the ancestor
chain and the method list untouched.

### `associations`

`{ association name => entry }`, present only for classes answering
`reflect_on_all_associations`.

| Field | What it holds | Used by |
| --- | --- | --- |
| `macro` | `has_many`, `belongs_to`, … | `association_changes` |
| `options` | `{ option name => readable value }`. Keys are recorded even when the value will not serialize, so an option arriving or vanishing is visible whatever it holds; an unserializable value becomes `<ClassName>` | `association_changes` |

Also invisible to every other section: the reader methods live in
`GeneratedAssociationMethods`, which is collapsed as a timing artifact, and a
reflection is neither a constant, an owned method, nor an ancestor.

### `methods`

An array of the methods the constant **owns directly** — inherited and included
ones belong to their real owner and are captured there. Sorted by
`kind, name, visibility`.

Two methods are "the same method" when `kind:name` matches
(`method_key`); everything else is what is then compared.

| Field | What it holds | Captured from | Used by |
| --- | --- | --- | --- |
| `name` | Method name | reflection | Half of the identity key; every row label |
| `kind` | `instance` or `singleton` | which reflector found it | The other half of the key; picks `ancestors` vs `singleton_ancestors` in the resolution pass; renders as `#` or `.` in a label |
| `visibility` | `public`, `protected` or `private` | which reflector found it | `visibility_changes` |
| `params` | `Method#parameters` flattened to `type:name` strings | reflection | `signature_diffs` — but only when there is no body digest to compare, i.e. native and gem methods |
| `file` | Normalized definition path | `source_location` | Row text |
| `line` | Definition line | `source_location` | Row text |
| `source` | How source text was resolved: `ruby`, `native`, `eval`, `internal`, `gem`, `generated`, `unreadable` | `method_source` | Nothing compares it. Its purpose is to keep the sidecar honest |
| `source_sha` | SHA-256 of normalized source text, `null` unless `source` is `ruby` | `method_source` | The key into the `.sources.json` sidecar |
| `body` | How the body digest was resolved: `iseq`, `native`, `gem`, `unavailable` | `body_digest` | — |
| `body_sha` | SHA-256 of the **normalized compiled instruction sequence** | `RubyVM::InstructionSequence.of(...).disasm` | `method_set_changes` — a `~` row. This is the comparison that matters |

`body_sha` rather than `source_sha` is what a changed body is judged on, and it
is why comments, formatting, file moves and namespacing do not count — only a
change in what the method actually does. It is also what makes dynamically
defined accessors comparable at all: they have no usable source text. When both
sides lack a body digest the comparator falls through to `params`, which is the
only `signature_diffs` ever fires.

A removed method is checked against B's chain before it is reported: if the name
still resolves there, the row says which ancestor now provides it. "This class
stopped defining it" and "this method is gone" are very different findings.

### `digests`

| Field | What it holds |
| --- | --- |
| `ancestors` | SHA-256 of the joined ancestor labels |
| `methods` | SHA-256 of the serialized method array |
| `all` | SHA-256 of superclass + the two above |

**No report reads these.** They exist for `record_constant`: when two live objects
claim one name, the entry with the lower `all` wins, so which one `ObjectSpace`
happened to yield first cannot change the file.

---

## The sidecar: `<label>.sources.json`

`{ source_sha => source text }`, written next to the snapshot whenever
`SNAPSHOT_SOURCE_TEXT=1` (the default). Only methods defined under `Rails.root`,
and only those whose extracted text actually starts with `def` /
`define_method` — a `source_location` on a metaprogrammed method points at the
line that *generated* it, and storing that line would fill the sidecar with
unrelated `include` statements.

**No report reads it.** It is there so that when a `~` row surprises you, you can
pull up both bodies by hand:

```bash
ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))[ARGV[1]]' \
  runtime-snapshot/snapshots/main-eager.sources.json <source_sha>
```

## What the report applies on top

Two inputs are not captured — they are transforms applied to the snapshots on the
way into the comparison:

- **`renames.json`** rewrites paths in A to their names in B before anything is
  compared, so a moved file is not a removal plus an addition. Built by
  `bin/renames` from `git diff -M`. See
  [RUNBOOK §3](RUNBOOK.md#3-build-the-rename-map).
- **`ignore.txt`** drops triaged rows. Its rule kinds are `constant`, `ancestor`,
  `file`, `method` and `section` — and a `section` rule takes exactly the ids in
  the **Used by** columns above. See
  [RUNBOOK §9](RUNBOOK.md#9-triage-with-the-ignore-list).

## Captured but unread

Nothing in either report reads the following. Most are diagnostic on purpose —
they are what you look at when a comparison surprises you, or when you are
deciding whether to trust a snapshot at all — but none of them can change a
count, a row or a warning.

| Field | Why it is there |
| --- | --- |
| `meta.generated_at`, `meta.hostname`, `meta.pid` | Identify the file after the fact. Quarantined here so the rest of the snapshot stays byte-stable |
| `paths.*` (all three) | Diagnosis: a `constants_missing` list that is really a missing eager-load path |
| `identity.autoloader`, `rails_version`, `ruby_version`, `capture_sources` | Provenance |
| `identity.root` | Every path is already normalized against it |
| `load_order.script_compiled` | Off unless `SNAPSHOT_TRACE_COMPILE=1`, and only meaningful with a cold Bootsnap cache |
| `load_order.dropped_class_events` | Tells you the class-body trace hit its buffer cap |
| `load_order.class_bodies[].kind`, `[].line` | Only `name` and `file` are consumed |
| `skipped`, `duplicate_names` and their `counts` entries | The two "may not be trustworthy" lists |
| `counts.*` except `autoloaded` | The stability check and eyeballing |
| `constants[].digests.*` | Used inside the dumper to break a duplicate-name tie |
| `constants[].kind` | Read by the cycles report, not the comparison report |
| `constants[].methods[].source`, `[].source_sha` | The sidecar's key and provenance; bodies are compared by iseq |
| `<label>.sources.json` | Reading a body by hand |

## Reverse index

Starting from a report instead of from a field. Sections in the order the
comparison report prints them.

| Report section | Fed by |
| --- | --- |
| header | `identity.label`, `.branch`, `.sha`, `.rails_env`, `.eager_load` |
| errors (refusal) | `identity.rails_env`, `.eager_load`, `.script_version` |
| warnings | `identity.script_version`, `.dirty`, `.preboot_trace_installed`, `.presumed_root_matched`, `.zeitwerk_enabled`, `.bootsnap_active`, `counts.autoloaded`, `autoload_registry.*`; plus the rename map and ignore list |
| `constants_missing` | `constants` key set, minus renames; row text from `origin`, `const_file`, `const_line` |
| `constants_extra` | the same, other direction |
| `superclass_changes` | `constants[].superclass` |
| `constant_value_changes` | `constants[].values{}.sha`, `.kind` |
| `association_changes` | `constants[].associations{}.macro`, `.options` |
| `class_attribute_changes` | `constants[].class_attributes{}.chains` (membership) |
| `resolution_order_changes` | `constants[].ancestors`, `.singleton_ancestors`, `ancestor_methods` |
| `method_set_changes` | `constants[].methods[].{name,kind,body_sha}`; `load_order.class_bodies[].name` for the `opened by` context |
| `visibility_changes` | `constants[].methods[].visibility` |
| `signature_diffs` | `constants[].methods[].params`, when no `body_sha` on either side |
| `class_attribute_order_only` | `constants[].class_attributes{}.chains` (order only) |
| `constant_value_order_only` | `constants[].values{}.order_sha` |
| `resolution_super_only` | `constants[].ancestors`, `ancestor_methods` |
| `attribute_ownership_only` | `constants[].singleton_ancestors`, `.class_attributes{}.chains`, `.methods` |
| `files_only_a` / `files_only_b` | union of `load_order.files`, `.autoloaded`, `.class_bodies[].file` |
| `autoload_managed_only_a` / `_only_b` | union of `autoload_registry`'s three lists |
| Rename map applied | `renames.json`, not the snapshot |

And the re-entrant load report (`bin/cycles`), which reads one snapshot:

| Input | Used as |
| --- | --- |
| `identity.label` | Report title |
| `load_order.class_bodies[].file` | Start clock — first index at which each file opened a body |
| `load_order.files` | `$LOADED_FEATURES` completion clock |
| `load_order.autoloaded` | `Dependencies.history` completion clock, refused if sorted |
| `constants[].const_file`, `[].kind` | Attributing a file back to the constant it defines |

See [RUNBOOK §14](RUNBOOK.md#14-finding-re-entrant-loads) for what it does with them.
