Pod::Spec.new do |s|
  s.name             = 'lucida_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Lucida Flutter plugin: AdServices install attribution token.'
  s.homepage         = 'https://github.com/lucidaanalytics/lucida-flutter'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'Lucida' => 'sdk@lucida.dev' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.weak_frameworks  = 'AdServices'
end
