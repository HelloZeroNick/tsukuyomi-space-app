Pod::Spec.new do |s|
  s.name = 'tsukuyomi_live2d'
  s.version = '0.1.0'
  s.summary = 'Cubism native GPU external textures'
  s.homepage = 'https://github.com/redchenk/tsukuyomi-space-app'
  s.license = { :type => 'MIT' }
  s.author = { 'Tsukuyomi Space' => 'https://github.com/redchenk' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/TsukuyomiLive2dPlugin.h'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.frameworks = 'Metal', 'CoreVideo', 'ImageIO', 'CoreGraphics'
  s.ios.frameworks = 'Flutter'
  s.osx.frameworks = 'FlutterMacOS'
  s.requires_arc = true
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17' }
end
