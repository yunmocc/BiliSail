Pod::Spec.new do |s|
  s.name             = 'bili_player_apple'
  s.version          = '0.1.0'
  s.summary          = 'AVPlayer backend for BiliSail.'
  s.description      = 'Native AVPlayer session, AVPlayerLayer, HLS/DASH composition and PiP for BiliSail.'
  s.homepage         = 'https://github.com/CKopoer/BiliSail'
  s.license          = { :type => 'MIT' }
  s.author           = { 'BiliSail' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.dependency 'Flutter'
  s.frameworks       = 'AVFoundation', 'AVKit', 'CoreMedia', 'UIKit'
end
