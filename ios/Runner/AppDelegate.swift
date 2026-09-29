import Flutter
import UIKit
import AudioToolbox

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(name: "number_bomb/feedback", binaryMessenger: engineBridge.applicationRegistrar.messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "play":
        AudioServicesPlaySystemSound(call.arguments as? String == "explosion" ? 1057 : 1104)
        result(nil)
      case "vibrate":
        let pattern = call.arguments as? String ?? "explosion"
        self.playVibration(pattern)
        result(nil)
      case "stop":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func playVibration(_ pattern: String) {
    let style: UIImpactFeedbackGenerator.FeedbackStyle
    switch pattern {
    case "dangerLow": style = .light
    case "dangerHigh": style = .medium
    default: style = .heavy
    }
    let generator = UIImpactFeedbackGenerator(style: style)
    generator.prepare()
    generator.impactOccurred()
    if pattern == "explosion" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
      }
    }
  }
}
