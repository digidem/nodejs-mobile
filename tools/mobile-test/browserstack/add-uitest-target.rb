#!/usr/bin/env ruby
# Add a transient XCUITest target (testnodeUITests) + a shared scheme to the
# testnode Xcode project, for the BrowserStack real-device smoke. Run at CI time on
# a scratch checkout — the modified project is a build input, never committed.
# Using the xcodeproj gem keeps the pbxproj edit correct-by-construction
# instead of hand-maintaining target boilerplate in the repo.
#
# Usage: ruby add-uitest-target.rb <path/to/testnode.xcodeproj>
require 'xcodeproj'

project_path = ARGV[0] or abort 'usage: add-uitest-target.rb <xcodeproj>'
project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |t| t.name == 'testnode' } \
  or abort 'testnode target not found'

test_target = project.new_target(:ui_test_bundle, 'testnodeUITests', :ios, '13.0')
test_target.add_dependency(app_target)

# Compile the checked-in smoke test source.
src = File.expand_path('testnodeUITests/SmokeUITest.m', __dir__)
group = project.new_group('testnodeUITests')
file_ref = group.new_file(src)
test_target.add_file_references([file_ref])

test_target.build_configurations.each do |config|
  config.build_settings['TEST_TARGET_NAME'] = app_target.name
  # This old project defines no project-level PRODUCT_NAME, so the setting
  # resolves empty for a generated target ("-Runner.app/PlugIns/.xctest")
  # unless pinned explicitly.
  config.build_settings['PRODUCT_NAME'] = 'testnodeUITests'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'nodejsmobile.test.uitests'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
end

project.save

# Shared scheme with a test action covering the UI test target, so
# `xcodebuild build-for-testing -scheme testnode-bs` works headless (the repo
# ships no shared schemes and xcodebuild cannot use Xcode's auto-schemes).
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.add_test_target(test_target)
scheme.set_launch_target(app_target)
scheme.save_as(project_path, 'testnode-bs', true)

puts "Added testnodeUITests target + testnode-bs scheme to #{project_path}"
