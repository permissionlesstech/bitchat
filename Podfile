use_frameworks!

# iOS target
platform :ios, '16.0'
target 'bitchat_iOS' do
  pod 'TorManager', '~> 0.4'
  # Include GeoIP subpod on iOS to ensure simulator slices and avoid undefined Tor C symbols on simulator
  pod 'Tor/GeoIP', '~> 408.17'
  pod 'IPtProxyUI', '4.8.1'
end

