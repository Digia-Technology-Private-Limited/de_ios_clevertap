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
  s.platform         = :ios, '15.0'
  s.swift_version    = '6.0'
  s.source_files     = 'Sources/DigiaEngageCleverTap/**/*.swift'

  # A range, never an exact pin: CocoaPods has to satisfy every podspec in the
  # host app's graph at once, and two exact pins on the same pod deadlock
  # resolution outright — the clevertap_plugin 3.8.1 failure mode. '1.0.0' was
  # also stale: core has been on 3.x since long before this plugin shipped.
  s.dependency 'DigiaEngage', '~> 4.0'
  # Same reasoning as DigiaEngage above, and more urgent: a host app almost
  # certainly already depends on CleverTap, so an exact pin here is the pin most
  # likely to meet another one. 7.5.1 is the floor, not the version.
  s.dependency 'CleverTap-iOS-SDK', '>= 7.5.1', '< 8.0'
end
