use_frameworks!

# iOS target
platform :ios, '16.0'
target 'bitchat_iOS' do
  pod 'TorManager', '~> 0.4'
  # Include GeoIP subpod on iOS to ensure simulator slices and avoid undefined Tor C symbols on simulator
  pod 'Tor/GeoIP', '~> 408.17'
end

# macOS target
platform :osx, '13.0'
target 'bitchat_macOS' do
  pod 'TorManager', '~> 0.4'
end
