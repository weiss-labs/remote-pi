# Plan/74 — add the ShareExtension target to Runner.xcodeproj (idempotent).
# Run from app/ios:  GEM_PATH=<cocoapods libexec>:$(gem env gempath) ruby add_share_extension.rb
require 'xcodeproj'

project = Xcodeproj::Project.open('Runner.xcodeproj')
runner = project.targets.find { |t| t.name == 'Runner' }
raise 'Runner target missing' unless runner

# Shared/ShareQueue.swift compiles into both targets.
shared_group = project.main_group['Shared'] || project.main_group.new_group('Shared', 'Shared')
queue_ref = shared_group.files.find { |f| f.path == 'ShareQueue.swift' } || shared_group.new_file('ShareQueue.swift')
runner_group = project.main_group['Runner']
bridges_ref = runner_group.files.find { |f| f.path == 'AttachmentBridges.swift' } || runner_group.new_file('AttachmentBridges.swift')
[queue_ref, bridges_ref].each do |ref|
  runner.source_build_phase.add_file_reference(ref, true) unless runner.source_build_phase.files_references.include?(ref)
end

ext = project.targets.find { |t| t.name == 'ShareExtension' }
unless ext
  ext = project.new_target(:app_extension, 'ShareExtension', :ios, '18.0')
  ext_group = project.main_group.new_group('ShareExtension', 'ShareExtension')
  vc = ext_group.new_file('ShareViewController.swift')
  ext_group.new_file('Info.plist')
  ext_group.new_file('ShareExtension.entitlements')
  ext.source_build_phase.add_file_reference(vc, true)
  ext.source_build_phase.add_file_reference(queue_ref, true)
  # Foundation is implicit for Swift; the gem's SDK-versioned framework ref would go stale.
  ext.frameworks_build_phase.files.each(&:remove_from_project)
  if (fw = project.frameworks_group.files.find { |f| f.path.to_s.end_with?('Foundation.framework') }) then fw.remove_from_project end
  generated = project.files.find { |f| f.path.to_s.end_with?('Generated.xcconfig') }
  ext.build_configurations.each do |config|
    config.base_configuration_reference = generated if generated
    s = config.build_settings
    s.delete('CODE_SIGN_STYLE')
    s['PRODUCT_BUNDLE_IDENTIFIER'] = 'ai.weisslabs.remotepi.share'
    s['PRODUCT_NAME'] = '$(TARGET_NAME)'
    s['INFOPLIST_FILE'] = 'ShareExtension/Info.plist'
    s['CODE_SIGN_ENTITLEMENTS'] = 'ShareExtension/ShareExtension.entitlements'
    s['DEVELOPMENT_TEAM'] = 'AH8UQ54A3J'
    s['SWIFT_VERSION'] = '5.0'
    s['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
    s['TARGETED_DEVICE_FAMILY'] = '1,2'
    s['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
    s['MARKETING_VERSION'] = '$(FLUTTER_BUILD_NAME)'
    s['SKIP_INSTALL'] = 'YES'
    s['GENERATE_INFOPLIST_FILE'] = 'NO'
    s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
    if config.name == 'Debug'
      s['CODE_SIGN_STYLE'] = 'Automatic'
      s['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = 'iPhone Developer'
    else
      s['CODE_SIGN_STYLE'] = 'Manual'
      s['PROVISIONING_PROFILE_SPECIFIER'] = 'Remote Pi WL Share Direct Push'
      s['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = 'Apple Distribution'
    end
  end
  runner.add_dependency(ext)
  embed = runner.new_copy_files_build_phase('Embed Foundation Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
  embed.add_file_reference(ext.product_reference, true).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  # Must run before Flutter's "Thin Binary" script or Xcode reports a cycle.
  phases = runner.build_phases
  phases.move(embed, phases.index(phases.find { |p| p.display_name == 'Thin Binary' }))
  # Products group tidy: Xcode puts new products there already.
end
# The app's own debug config signs with the same automatic style; keep untouched.
project.save
puts "targets: #{project.targets.map(&:name).join(', ')}"
