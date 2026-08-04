# script/dump_git_renames.rb
# frozen_string_literal: true

require "json"
require "open3"

# usage: ruby script/dump_git_renames.rb main HEAD > tmp/git-renames.json

base = ARGV[0] || "main"
head = ARGV[1] || "HEAD"

merge_base_cmd = ["git", "merge-base", base, head]
merge_base, merge_base_status = Open3.capture2(*merge_base_cmd)

unless merge_base_status.success?
  abort "Failed to find merge-base for #{base.inspect} and #{head.inspect}"
end

merge_base = merge_base.strip

# --name-status gives machine-ish rename records:
#   R100 old/path.rb new/path.rb
#   R087 old/path.rb new/path.rb
#
# -M enables rename detection.
# -C can also detect copies, but for this use case renames are usually what we want.
cmd = [
  "git",
  "diff",
  "--name-status",
  "-M",
  "--find-copies-harder",
  "#{merge_base}..#{head}"
]

stdout, stderr, status = Open3.capture3(*cmd)

unless status.success?
  abort "git diff failed:\n#{stderr}"
end

moves_or_copies = []

stdout.each_line do |line|
  parts = line.chomp.split("\t")
  status_code = parts[0]

  next unless status_code&.match?(/\A[RC]/)

  kind = begin
    if status_code.start_with?("R")
      "rename"
    else
      "copy"
    end
  end

  similarity = status_code[1..].to_i
  old_path = parts[1]
  new_path = parts[2]

  moves_or_copies << {
    "kind" => kind,
    "old_path" => old_path,
    "new_path" => new_path,
    "similarity" => similarity,
    "status" => status_code
  }
end

output = {
  "base" => base,
  "head" => head,
  "merge_base" => merge_base,
  "rename_count" => moves_or_copies.size,
  "renames" => moves_or_copies.sort_by { |r| [r["old_path"], r["new_path"]] },
  "old_to_new" => moves_or_copies.to_h { |r| [r["old_path"], r["new_path"]] },
  "new_to_old" => moves_or_copies.to_h { |r| [r["new_path"], r["old_path"]] }
}

puts JSON.pretty_generate(output)
