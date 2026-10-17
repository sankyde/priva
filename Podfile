# Embedded Tor (onion mode). The pod downloads the official prebuilt tor.xcframework from
# github.com/iCepa/Tor.framework releases and verifies it against pinned SHA-256 hashes.
platform :ios, '26.0'
project 'Priva.xcodeproj'
install! 'cocoapods', :warn_for_unused_master_specs_repo => false

target 'Priva' do
  use_frameworks! :linkage => :static
  pod 'Tor/CTor-NoLZMA', '~> 409.12'

  target 'PrivaTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
    end
  end
end
