import Flutter
import UIKit

public class FlutterBlindWatermarkPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    // FFI plugin - no method channel needed
    // This class exists only to satisfy Flutter's plugin registration requirement
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }
}
