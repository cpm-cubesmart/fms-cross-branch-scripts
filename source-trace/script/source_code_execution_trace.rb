# source-trace/script/source_code_execution_trace.rb
#
# Reports the first line executed in each file under the application root, in
# order, during boot and eager load.
#
# Run it directly rather than through `bin/rails runner` -- the trace has to be
# installed before config/environment is loaded, and a runner script only starts
# after boot has already finished.
#
#   cd ~/code/fms
#   DISABLE_SPRING=1 bundle exec ruby \
#     ../fms-cross-branch-scripts/source-trace/script/source_code_execution_trace.rb
#
# The application root defaults to the current directory; override with APP_ROOT
# if you need to run from somewhere else. (This script used to live inside the
# application and derive the root from its own location, which stopped working
# when it moved into this repository.)
#
# :line tracing is slow on a large application. If you only need to know which
# files loaded and in what order, runtime-snapshot's load_order is much cheaper
# and is not defeated by Bootsnap. Reach for this when you need to see execution
# actually reaching a particular line.

project_root = File.expand_path(ENV["APP_ROOT"] || Dir.pwd)

environment = File.join(project_root, "config", "environment.rb")

unless File.file?(environment)
  abort <<~ERROR
    No config/environment.rb under #{project_root}.

    Run this from the application directory:

      cd ~/code/fms
      DISABLE_SPRING=1 bundle exec ruby #{__FILE__}

    or set APP_ROOT=/path/to/app.
  ERROR
end

seen = {}

trace = TracePoint.new(:line) do |event|
  path = File.expand_path(event.path)

  next unless path.start_with?("#{project_root}/")
  next if seen[path]

  seen[path] = true

  relative_path = path.delete_prefix("#{project_root}/")

  warn format(
    "[SOURCE EXECUTION %04d] %s:%d",
    seen.length,
    relative_path,
    event.lineno
  )
end

trace.enable

require environment

Rails.application.eager_load!

trace.disable

warn "[SOURCE EXECUTION] #{seen.length} file(s) executed under #{project_root}"
