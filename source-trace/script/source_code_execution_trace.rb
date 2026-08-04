# script/trace_source_execution.rb

seen = {}

project_root = File.expand_path("..", __dir__)

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

require_relative "../config/environment"
Rails.application.eager_load!

