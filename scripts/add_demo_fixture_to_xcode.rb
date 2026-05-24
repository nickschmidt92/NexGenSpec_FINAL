#!/usr/bin/env ruby
# One-shot: add NexGenSpec/Debug/DemoModeFixture.swift to the Xcode project
# under the "Debug" group inside the NexGenSpec group, and link it into the
# NexGenSpec target. Idempotent — running twice does nothing the second time.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../NexGenSpec.xcodeproj', __dir__)
TARGET_NAME  = 'NexGenSpec'
GROUP_NAME   = 'NexGenSpec'
SUBGROUP     = 'Debug'
FILE_REL     = 'Debug/DemoModeFixture.swift'  # relative to the NexGenSpec group's source root
FILE_ABS     = File.expand_path("../NexGenSpec/#{FILE_REL}", __dir__)

abort "fixture file missing at #{FILE_ABS}" unless File.exist?(FILE_ABS)

project = Xcodeproj::Project.open(PROJECT_PATH)
target  = project.targets.find { |t| t.name == TARGET_NAME } or abort "target #{TARGET_NAME} not found"
parent  = project.main_group[GROUP_NAME] or abort "group #{GROUP_NAME} not found"

# Find or create the Debug subgroup
debug_group = parent.children.find { |c| c.respond_to?(:name) && (c.name == SUBGROUP || c.display_name == SUBGROUP) }
unless debug_group
  debug_group = parent.new_group(SUBGROUP, SUBGROUP)
  puts "+ created group: #{GROUP_NAME}/#{SUBGROUP}"
end

# Check if file is already referenced anywhere in the project
already = project.files.find { |f| f.real_path.to_s == FILE_ABS }
if already
  puts "= already referenced: #{FILE_REL}"
else
  file_ref = debug_group.new_reference(FILE_ABS)
  file_ref.source_tree = '<group>'
  puts "+ added file reference: #{FILE_REL}"
end

# Ensure it's in the compile sources phase of the target
file_ref = already || debug_group.files.find { |f| f.real_path.to_s == FILE_ABS }
if target.source_build_phase.files_references.include?(file_ref)
  puts "= already in compile sources of #{TARGET_NAME}"
else
  target.add_file_references([file_ref])
  puts "+ added to compile sources of #{TARGET_NAME}"
end

project.save
puts "✓ saved #{File.basename(PROJECT_PATH)}"
