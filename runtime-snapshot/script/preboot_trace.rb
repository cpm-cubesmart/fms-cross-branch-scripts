# runtime-snapshot/script/preboot_trace.rb
# frozen_string_literal: true
#
# RUBYOPT preload hook. Loaded via:
#
#   RUBYOPT="-r/abs/path/to/preboot_trace.rb" DISABLE_SPRING=1 bin/rails runner ...
#
# WHY THIS EXISTS
#
# `bin/rails runner` executes its script *after* the application has finished
# booting. A TracePoint installed inside the runner script therefore misses the
# entire boot -- which is exactly the window we care about when comparing a
# classic-autoloader boot (explicit `require`s in config/application.rb) against
# a Zeitwerk boot.
#
# This file runs before anything else: before Bundler, before config/boot.rb,
# before config/application.rb. It records a baseline and installs the traces,
# then stashes everything in $FMS_SNAPSHOT_TRACE for dump_runtime_snapshot.rb
# to harvest.
#
# Constraints: no gems (Bundler has not run yet), no Rails (does not exist yet),
# and it must be cheap enough that it does not distort the boot it observes.

# Idempotency guard. RUBYOPT applies to every Ruby process in the tree, and a
# re-exec (or a nested `ruby` call) would otherwise reinstall the traces and
# clobber the baseline we already captured.
unless defined?($FMS_SNAPSHOT_TRACE) && $FMS_SNAPSHOT_TRACE

  $FMS_SNAPSHOT_TRACE = {
    installed: true,
    install_pid: Process.pid,

    # $LOADED_FEATURES as it stood before the app began booting. Everything
    # appended after this point is attributable to the boot.
    loaded_features_baseline: $LOADED_FEATURES.dup,

    # Best guess at the application root. `bin/rails` is essentially always
    # invoked from the app directory (and bin/snapshot cds there explicitly).
    # Used to filter trace events cheaply, since Rails.root does not exist yet.
    # The dumper cross-checks this against the real Rails.root and warns on a
    # mismatch.
    presumed_root: Dir.pwd,

    class_events: [],
    script_compiled: [],
    tracepoints: [],
    dropped_class_events: 0
  }

  presumed_root = $FMS_SNAPSHOT_TRACE[:presumed_root]
  root_prefix = "#{presumed_root}/"

  # Recording every :class event in the process (including deep gem internals)
  # costs memory and adds noise. By default we keep only events whose file lives
  # under the app root -- which still captures app code reopening a gem class,
  # because that reopening happens in an app file. Set SNAPSHOT_TRACE_ALL=1 to
  # keep everything.
  trace_all = ENV["SNAPSHOT_TRACE_ALL"] == "1"

  class_events = $FMS_SNAPSHOT_TRACE[:class_events]

  # Every :class event, in order, including repeat openings of the same class.
  # The repeats are the point: when a monkey patch reopens a class relative to
  # the original definition is precisely what changes between classic and
  # Zeitwerk, and it is what decides which definition of a method wins.
  class_trace = TracePoint.new(:class) do |tp|
    path = tp.path

    if trace_all || (path.is_a?(String) && path.start_with?(root_prefix))
      mod = tp.self

      # Some modules override `name` (the classic example in this repo's
      # history is REXML::Functions). Bind the real Module#name instead of
      # dispatching, so a hostile override cannot corrupt or crash the trace.
      name =
        begin
          Module.instance_method(:name).bind(mod).call
        rescue Exception # rubocop:disable Lint/RescueException
          nil
        end

      kind =
        begin
          Module.instance_method(:is_a?).bind(mod).call(Class) ? "class" : "module"
        rescue Exception # rubocop:disable Lint/RescueException
          "unknown"
        end

      class_events << [name, kind, path, tp.lineno]
    else
      $FMS_SNAPSHOT_TRACE[:dropped_class_events] += 1
    end
  end

  class_trace.enable
  $FMS_SNAPSHOT_TRACE[:tracepoints] << class_trace

  # Optional and off by default: :script_compiled fires when a file is compiled,
  # which Bootsnap defeats by serving cached instruction sequences. It is useful
  # on a cold cache (or with DISABLE_BOOTSNAP=1) but must never be the primary
  # load-order source -- $LOADED_FEATURES is, because the VM appends to it
  # regardless of caching and regardless of whether the require came from Ruby
  # code or from a C-level autoload trigger.
  if ENV["SNAPSHOT_TRACE_COMPILE"] == "1"
    script_compiled = $FMS_SNAPSHOT_TRACE[:script_compiled]

    compile_trace = TracePoint.new(:script_compiled) do |tp|
      path =
        begin
          tp.instruction_sequence.path
        rescue Exception # rubocop:disable Lint/RescueException
          nil
        end

      script_compiled << path if path.is_a?(String)
    end

    compile_trace.enable
    $FMS_SNAPSHOT_TRACE[:tracepoints] << compile_trace
  end
end
