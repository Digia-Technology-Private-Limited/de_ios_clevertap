Pod::Spec.new do |s|
  s.name             = 'DigiaEngageCleverTap'
  s.version          = '1.0.0'
  s.summary          = 'Digia Engage CleverTap plugin for iOS.'
  s.description      = <<-DESC
    Routes CleverTap custom-template campaigns and display units into Digia Engage.
  DESC
  s.homepage         = 'https://github.com/Digia-Technology-Private-Limited/digia_engage_clevertap_ios'
  s.license          = { :type => 'BSL-1.1', :file => 'LICENSE' }
  s.author           = { 'Digia Engg' => 'engg@digia.tech' }
  s.source           = {
    :git => 'https://github.com/Digia-Technology-Private-Limited/digia_engage_clevertap_ios.git',
    :tag => s.version.to_s
  }
  s.platform         = :ios, '16.0'
  s.swift_version    = '6.0'
  s.source_files     = 'Sources/DigiaEngageCleverTap/**/*.swift'

  s.dependency 'DigiaEngage', '1.0.0'
  s.dependency 'CleverTap-iOS-SDK', '7.5.1'
end
