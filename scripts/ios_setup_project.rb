# Adds the native iPad sources and the ReplayKit broadcast extension target
# to ios/Runner.xcodeproj. Idempotent: safe to run again after `flutter create`
# regenerates the project.
#
#   gem install xcodeproj
#   ruby scripts/ios_setup_project.rb

require 'xcodeproj'

ROOT = File.expand_path('../ios', __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, 'Runner.xcodeproj'))
runner = project.targets.find { |t| t.name == 'Runner' } or abort 'Runner target not found'

APP_SOURCES = %w[ObsEncoderPlugin.swift AppEncoders.swift Mp4Writer.swift ScreenReceiver.swift].freeze
SHARED_SOURCES = %w[ObsLink.swift H264Encoder.swift Compositor.swift].freeze
EXT_NAME = 'BroadcastExtension'.freeze

def group_for(project, name, path)
  project.main_group.children.find { |g| g.display_name == name } ||
    project.main_group.new_group(name, path)
end

def file_ref(group, name)
  group.files.find { |f| f.path == name } || group.new_reference(name)
end

def add_source(target, ref)
  target.source_build_phase.add_file_reference(ref, true)
end

# --- App sources --------------------------------------------------------------
runner_group = group_for(project, 'Runner', 'Runner')
APP_SOURCES.each { |f| add_source(runner, file_ref(runner_group, f)) }
file_ref(runner_group, 'Runner.entitlements')

shared_group = group_for(project, 'Shared', 'Shared')
shared_refs = SHARED_SOURCES.map { |f| file_ref(shared_group, f) }
shared_refs.each { |r| add_source(runner, r) }

runner.build_configurations.each do |c|
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

# --- Broadcast extension target ---------------------------------------------
ext = project.targets.find { |t| t.name == EXT_NAME }
unless ext
  ext = project.new_target(:app_extension, EXT_NAME, :ios, '15.0', nil, :swift)
end

ext_group = group_for(project, EXT_NAME, EXT_NAME)
add_source(ext, file_ref(ext_group, 'SampleHandler.swift'))
file_ref(ext_group, 'Info.plist')
file_ref(ext_group, "#{EXT_NAME}.entitlements")
shared_refs.each { |r| add_source(ext, r) }

%w[ReplayKit VideoToolbox CoreImage CoreMedia].each do |fw|
  path = "System/Library/Frameworks/#{fw}.framework"
  next if ext.frameworks_build_phase.files_references.any? { |r| r.path == path }
  ext.add_system_framework(fw)
end

flutter_group = project.main_group.children.find { |g| g.display_name == 'Flutter' }
ext_xcconfig = flutter_group.files.find { |f| f.path == 'Extension.xcconfig' } ||
               flutter_group.new_reference('Extension.xcconfig')

app_bundle_id = runner.build_configurations.first.build_settings['PRODUCT_BUNDLE_IDENTIFIER']
ext.build_configurations.each do |c|
  c.base_configuration_reference = ext_xcconfig
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{app_bundle_id}.#{EXT_NAME}"
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_NAME}/#{EXT_NAME}.entitlements"
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['SWIFT_VERSION'] = '5.0'
  s['SKIP_INSTALL'] = 'YES'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks',
                                  '@executable_path/../../Frameworks']
  s['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
  s['MARKETING_VERSION'] = '$(FLUTTER_BUILD_NAME)'
  # Copy the app's team so automatic signing works for both targets.
  team = runner.build_configurations.find { |rc| rc.name == c.name }&.build_settings&.[]('DEVELOPMENT_TEAM')
  s['DEVELOPMENT_TEAM'] = team if team
end

# Embed the extension in the app.
runner.add_dependency(ext) unless runner.dependencies.any? { |d| d.target == ext }
embed = runner.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }
unless embed
  embed = runner.new_copy_files_build_phase('Embed Foundation Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
end
unless embed.files_references.include?(ext.product_reference)
  bf = embed.add_file_reference(ext.product_reference, true)
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
# Must run before Flutter's "Thin Binary" script, or Xcode reports a
# dependency cycle (flutter/flutter#135056).
phases = runner.build_phases
phases.delete(embed)
thin = phases.index { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
phases.insert(thin || phases.length, embed)

project.save
puts "Configured #{runner.name} + #{ext.name} (#{app_bundle_id}.#{EXT_NAME})"
