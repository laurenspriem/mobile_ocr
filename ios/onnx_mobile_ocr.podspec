#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint onnx_mobile_ocr.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'onnx_mobile_ocr'
  s.version          = '0.0.1'
  s.summary          = 'Flutter plugin for on-device OCR using native iOS Vision framework.'
  s.description      = <<-DESC
A Flutter plugin for on-device OCR using native iOS Vision framework.
Provides text detection and recognition capabilities without requiring external model downloads.
                       DESC
  s.homepage         = 'https://github.com/laurenspriem/onnx_mobile_ocr'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Ente' => 'support@ente.io' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.ios.deployment_target = '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Specify frameworks
  s.frameworks = 'Vision', 'CoreImage', 'UIKit'
end