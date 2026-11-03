#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Generate DSHPortC.xcodeproj for the "native Node inside an iOS app" task.
#
# Deterministic and repeatable: the project file is a build artifact, so it is
# generated rather than hand-edited. Re-run after adding/removing sources.
#
# Usage:
#   GEM_HOME=$PWD/tools/gems GEM_PATH=$PWD/tools/gems \
#     /usr/bin/ruby scripts/gen-xcode-project.rb
#
# Layout it produces:
#   app/DSHPortC.xcodeproj
#   app/DSHPortC/*.swift            (sources, auto-globbed)
#   app/DSHPortC/*.h or .m/.mm      (objc sources, if any)
#   app/DSHPortC/Info.plist         (copied to the bundle)
#   app/DSHPortC/Assets.xcassets    (optional)
#   vendor/nodejs-mobile/NodeMobile.xcframework  (embedded framework)
#   payload/                        (folder reference resource: the trimmed dsh tree)
#   sim/                            (folder reference resource: the JS shims)

require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
APP_DIR = File.join(ROOT, 'app')
PROJECT_PATH = File.join(APP_DIR, 'DSHPortC.xcodeproj')
TARGET_NAME = 'DSHPortC'
BUNDLE_ID = 'local.dshportc.app'
DEPLOYMENT_TARGET = '17.0'

NODE_FRAMEWORK = File.join(ROOT, 'vendor/nodejs-mobile/NodeMobile.xcframework')

# --- embedded iSH kernel ---------------------------------------------------
# The app links three static libraries built by ish/scripts/build-ish.sh and
# compiles against the pinned source tree's headers. Both are build products of
# a script, not files under version control, so the generator only records where
# they will be and the build fails with a clear message if they are absent.
ISH_ROOT = File.join(ROOT, 'ish')
ISH_SRC = File.join(ISH_ROOT, 'src/ish-arm64')
# One build directory per SDK: the device and simulator slices live side by side
# (ish/scripts/build-ish.sh -p iphoneos|iphonesimulator) and the linker flags
# below pick one by SDK, so a single project builds for either.
ISH_LIBS_SIM = File.join(ROOT, 'build/ish/iphonesimulator/Release/ninja')
ISH_LIBS_DEV = File.join(ROOT, 'build/ish/iphoneos/Release/ninja')
ISH_LIBS = ISH_LIBS_SIM
ISH_VDSO = File.join(ISH_LIBS, 'vdso/arm64/libvdso.so.elf')
ROOTFS_DIR = File.join(ROOT, 'build/rootfs')
PAYLOAD_DIR = File.join(ROOT, 'payload')
SIM_DIR = File.join(ROOT, 'sim')
PROFILES_DIR = File.join(ROOT, 'profiles')
# Task-owned DSH plugins (the subprocess provider, the iOS sandbox provider, the
# approval policy). Copied as a tree so a plugin can be added or edited without
# touching the generated project file.
PLUGINS_DIR = File.join(ROOT, 'plugins')

abort "missing NodeMobile.xcframework at #{NODE_FRAMEWORK}" unless Dir.exist?(NODE_FRAMEWORK)

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastUpgradeCheck'] = '2700'

group = project.main_group.new_group(TARGET_NAME, 'DSHPortC')
target = project.new_target(:application, TARGET_NAME, :ios, DEPLOYMENT_TARGET)

# ---------------------------------------------------------------- sources
source_paths = Dir.glob(File.join(APP_DIR, TARGET_NAME, '*.{swift,m,mm,c}')).sort
abort 'no sources found' if source_paths.empty?
source_paths.each do |path|
  # The group already points at app/DSHPortC, so the reference is the basename.
  ref = group.new_reference(File.basename(path))
  target.add_file_references([ref])
end
puts "sources: #{source_paths.map { |p| File.basename(p) }.join(', ')}"

# --- iSH kernel sources the app target compiles itself ---------------------
# Everything else lives in the three static libraries. What has to be compiled
# here is the C that the kernel does not put in the libraries: the assembly the
# linker needs to resolve gadget tables, and the platform file that provides the
# host-side syscall glue. Keeping this list explicit (rather than globbing the
# whole tree) is what makes a missing library a link error instead of a subtly
# different kernel.
ish_extra_sources = [
  # Nothing yet: the libraries are self-contained and the app links them whole.
]
ish_extra_sources.each do |rel|
  abs = File.join(ISH_SRC, rel)
  abort "missing iSH source #{abs}" unless File.exist?(abs)
  ref = project.main_group.new_reference(abs, :group)
  ref.name = File.basename(rel)
  target.add_file_references([ref])
end

# Info.plist (referenced, not compiled)
info_plist = File.join(APP_DIR, TARGET_NAME, 'Info.plist')
abort "missing Info.plist at #{info_plist}" unless File.exist?(info_plist)

# Assets catalogue, if present.
#
# Step 15 added one for a single reason: the launch screen needs a colour that
# has a light and a dark variant, and a colour asset is the only way to give
# `UILaunchScreen` one.
#
# Step 21 added the app icon (`AppIcon.appiconset`) and the launch-screen mark
# (`LaunchMark.imageset`) to the same catalogue. Xcode's default
# `ASSETCATALOG_COMPILER_APPICON_NAME` is `AppIcon` whether or not the catalogue
# has one, which is why step 15 had to clear it: a catalogue without the set
# fails the build with "none of the input catalogs contained a matching … icon
# set named AppIcon". Now the set is there, so the name is set explicitly — a
# missing icon becomes a build error again instead of a silently blank icon.
HAS_ASSETS = Dir.exist?(File.join(APP_DIR, TARGET_NAME, 'Assets.xcassets'))
HAS_APP_ICON = Dir.exist?(File.join(APP_DIR, TARGET_NAME, 'Assets.xcassets', 'AppIcon.appiconset'))
if HAS_ASSETS
  ref = group.new_reference('Assets.xcassets')
  target.add_resources([ref])
end

# Settings.bundle: the four notification switches, in the iOS Settings app.
#
# A bundle, copied whole (it is a directory with its own Info.plist), not a
# flattened set of files. Step 16's task puts this second: DSH's own settings page
# cannot render a plugin's configuration automatically (it is a shell whose tabs are
# contributed by client packages, and the only shipped tab is a read-only
# inventory), so the switches live where iOS already puts per-app preferences. The
# keys in Root.plist are the same `UserDefaults` keys the in-app sheet writes, so
# the two places edit one value.
settings_bundle = File.join(APP_DIR, TARGET_NAME, 'Settings.bundle')
if Dir.exist?(settings_bundle)
  ref = group.new_reference('Settings.bundle')
  target.add_resources([ref])
end

# ------------------------------------------------- folder-reference resources
# `payload/` and `sim/` are copied as directory trees, not flattened, so the JS
# side can resolve paths relative to the bundle without a manifest.
def add_folder_reference(project, target, absolute_path, name)
  abort "missing #{absolute_path}" unless Dir.exist?(absolute_path)
  ref = project.main_group.new_reference(absolute_path, :group)
  ref.name = name
  ref.source_tree = 'SOURCE_ROOT'
  build_file = project.new_file(absolute_path)
  target.add_resources([ref])
  build_file.remove_from_project
  ref
end

# The guest image and its version stamp. A folder reference is not used because
# the app looks them up by name via Bundle.main; two plain file references keep
# the names intact.
[['ish-rootfs.tar.gz', ROOTFS_DIR], ['ish-rootfs.version', ROOTFS_DIR]].each do |name, dir|
  abs = File.join(dir, name)
  unless File.exist?(abs)
    puts "WARNING: #{abs} does not exist — build it with ish/scripts/build-rootfs.sh"
    next
  end
  ref = project.main_group.new_reference(abs, :group)
  ref.name = name
  target.add_resources([ref])
end

add_folder_reference(project, target, PAYLOAD_DIR, 'payload')
add_folder_reference(project, target, SIM_DIR, 'sim')
add_folder_reference(project, target, PLUGINS_DIR, 'plugins')
# `profiles/` ships the ios-sim profile template the host copies into DSH_HOME.
add_folder_reference(project, target, PROFILES_DIR, 'profiles')

# ------------------------------------------------------------- node framework
fw_group = project.main_group.new_group('Frameworks')
fw_ref = fw_group.new_reference(NODE_FRAMEWORK, :group)
link_file = target.frameworks_build_phase.add_file_reference(fw_ref, true)
link_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy'] }

# Embed the framework into the app bundle's Frameworks/ directory.
embed = target.new_copy_files_build_phase('Embed Frameworks')
embed.symbol_dst_subfolder_spec = :frameworks
embed_file = embed.add_file_reference(fw_ref, true)
embed_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }

# ------------------------------------------------------------------ settings
target.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['INFOPLIST_FILE'] = 'DSHPortC/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['SWIFT_VERSION'] = '5.0'
  s['SWIFT_OBJC_BRIDGING_HEADER'] = 'DSHPortC/DSHPortC-Bridging-Header.h'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  s['CODE_SIGN_IDENTITY'] = '-'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGN_ENTITLEMENTS'] = 'DSHPortC/DSHPortC.entitlements'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  s['ENABLE_BITCODE'] = 'NO'
  s['CLANG_ENABLE_MODULES'] = 'YES'
  s['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks'
  s['OTHER_LDFLAGS'] = '$(inherited) -ObjC'
  # The NodeMobile slices are arm64-only for the simulator, so never emit x86_64.
  s['ARCHS[sdk=iphonesimulator*]'] = 'arm64'
  s['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'x86_64'
  s['SWIFT_OPTIMIZATION_LEVEL'] = config.name == 'Debug' ? '-Onone' : '-O'

  # The kernel headers refuse to compile without ISH_INTERNAL: they are the
  # emulator's internals and the fork marks them as such. Defining it here rather
  # than in each .m file means a file added later gets the same treatment.
  s['GCC_PREPROCESSOR_DEFINITIONS'] = '$(inherited) ISH_INTERNAL=1 GUEST_ARM64=1'
  # iSH's headers are included by relative path from the tree root ("kernel/...",
  # "fs/..."), so the root is a header search path. cpu-offsets.h is generated by
  # meson into the build directory, not the source tree, which is why that one is
  # listed separately.
  { 'iphonesimulator*' => ISH_LIBS_SIM, 'iphoneos*' => ISH_LIBS_DEV }.each do |sdk, libs|
    s["HEADER_SEARCH_PATHS[sdk=#{sdk}]"] = [
      '$(inherited)',
      ISH_SRC,
      libs,
      File.join(ISH_SRC, 'deps/libarchive/libarchive'),
    ].join(' ')
  end
  # The three libraries are linked by path. libish_emu holds the ARM64 gadget
  # assembly, which is host arm64 code: the simulator must be arm64-only, which
  # the ARCHS settings below already enforce.
  s['OTHER_LDFLAGS'] = '$(inherited) -ObjC -lsqlite3 -lresolv -lz'
  { 'iphonesimulator*' => ISH_LIBS_SIM, 'iphoneos*' => ISH_LIBS_DEV }.each do |sdk, libs|
    s["OTHER_LDFLAGS[sdk=#{sdk}]"] = [
      '$(inherited)',
      '-ObjC',
      File.join(libs, 'libish.a'),
      File.join(libs, 'libish_emu.a'),
      File.join(libs, 'libfakefs.a'),
      '-lsqlite3',
      '-lresolv',
      '-lz',
    ].join(' ')
  end
  # Device builds are signed (development only). The identity itself is not
  # written here: it is passed on the xcodebuild command line by
  # scripts/build-device.sh, so the project file never names a
  # certificate. The simulator keeps the unsigned settings above.
  s['DEVELOPMENT_TEAM'] = ENV['DSH_TEAM_ID'].to_s
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['CODE_SIGNING_ALLOWED[sdk=iphoneos*]'] = 'YES'
  s['CODE_SIGNING_REQUIRED[sdk=iphoneos*]'] = 'YES'
  s['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = 'Apple Development'
  # Warnings from code this repository does not own are noise in a build log
  # people read for their own mistakes. The kernel is compiled with the flags its
  # own project chose; the app does not get to change that from here.
  s['GCC_WARN_INHIBIT_ALL_WARNINGS'] = 'YES'
  # See the Assets.xcassets comment above: step 21 ships an icon set, so it is
  # named here; before step 21 there was none and this had to be empty.
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = HAS_APP_ICON ? 'AppIcon' : '' if HAS_ASSETS
end


# ------------------------------------------------------------- UI test target
# Drives the real app so "the interface works" is a measured claim rather than a
# reading of the source. Built only when the directory exists; the normal build
# does not need it.
UI_TEST_DIR = File.join(APP_DIR, 'DSHPortCUITests')
if Dir.exist?(UI_TEST_DIR) && !ENV['DSHPORTC_SKIP_UI_TESTS']
  ui_group = project.main_group.new_group('DSHPortCUITests', 'DSHPortCUITests')
  ui_target = project.new_target(:ui_test_bundle, 'DSHPortCUITests', :ios, DEPLOYMENT_TARGET)
  Dir.glob(File.join(UI_TEST_DIR, '*.swift')).sort.each do |path|
    ref = ui_group.new_reference(File.basename(path))
    ui_target.add_file_references([ref])
  end
  ui_target.add_dependency(target)
  ui_target.build_configurations.each do |config|
    s = config.build_settings
    s['PRODUCT_BUNDLE_IDENTIFIER'] = 'local.dshportc.uitests'
    s['TEST_TARGET_NAME'] = TARGET_NAME
    s['GENERATE_INFOPLIST_FILE'] = 'YES'
    s['SWIFT_VERSION'] = '5.0'
    s['CODE_SIGNING_ALLOWED'] = 'NO'
    s['CODE_SIGNING_REQUIRED'] = 'NO'
    s['CODE_SIGN_IDENTITY'] = '-'
    s['TARGETED_DEVICE_FAMILY'] = '1,2'
    s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
    s['ARCHS[sdk=iphonesimulator*]'] = 'arm64'
    s['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'x86_64'
  end
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(target)
  scheme.add_test_target(ui_target)
  scheme.set_launch_target(target)
  scheme.save_as(PROJECT_PATH, TARGET_NAME, true)
  puts "UI test target: DSHPortCUITests"
end

project.save
puts "wrote #{PROJECT_PATH}"
