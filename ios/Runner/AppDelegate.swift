import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // CRITICAL: register our audio session as an arbitration peer in the
        // foreground at app launch — BEFORE the user can start playing Music.
        // iOS only grants the "duck Music when I speak" capability to sessions
        // it sees first activated in the foreground. Skip this and Music
        // preempts us whenever it starts playing in background.
        WorkoutManager.configureAudioCategory()
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

        guard let messenger = engineBridge.pluginRegistry.registrar(
            forPlugin: "SteadyHeartBeat"
        )?.messenger() else { return }

        // Method channel: commands from Flutter → native
        let methodChannel = FlutterMethodChannel(
            name: "steadyheartbeat/workout",
            binaryMessenger: messenger
        )
        methodChannel.setMethodCallHandler { call, result in
            switch call.method {
            case "requestAuthorization":
                WorkoutManager.shared.requestAuthorization { success, error in
                    if let error = error, !success {
                        result(FlutterError(code: "AUTH_ERROR", message: error, details: nil))
                    } else {
                        result(success)
                    }
                }

            case "startWorkout":
                let args = call.arguments as? [String: Any]
                let workoutType = args?["type"] as? String ?? "other"
                let seconds = args?["seconds"] as? Int ?? 15
                WorkoutManager.shared.startWorkout(type: workoutType, announceIntervalSeconds: seconds) { success, error in
                    if let error = error, !success {
                        result(FlutterError(code: "START_ERROR", message: error, details: nil))
                    } else {
                        result(success)
                    }
                }

            case "stopWorkout":
                WorkoutManager.shared.stopWorkout()
                result(nil)

            case "checkAirPods":
                let info = WorkoutManager.shared.checkAirPodsInfo()
                result(info)

            case "bindAirPods":
                WorkoutManager.shared.bindAirPods { bound in result(bound) }

            case "setBoxingRounds":
                let a = call.arguments as? [String: Any]
                WorkoutManager.shared.setBoxingRounds(
                    enabled: a?["enabled"] as? Bool ?? false,
                    roundSecs: a?["roundSecs"] as? Int ?? 180,
                    restSecs: a?["restSecs"] as? Int ?? 60,
                    totalRounds: a?["totalRounds"] as? Int ?? 12,
                    warnSecs: a?["warnSecs"] as? Int ?? 10,
                    prepSecs: a?["prepSecs"] as? Int ?? 10)
                result(nil)

            case "getHealthProfile":
                result(WorkoutManager.shared.getHealthProfile())

            case "getRecentHRV":
                WorkoutManager.shared.getRecentHRV { data in result(data) }

            case "getRestingHR":
                WorkoutManager.shared.getRestingHR { data in result(data) }

            case "getVO2Max":
                WorkoutManager.shared.getVO2Max { data in result(data) }

            case "getBodyMass":
                WorkoutManager.shared.getBodyMass { data in result(data) }

            case "setVoice":
                let identifier = (call.arguments as? [String: Any])?["identifier"] as? String ?? ""
                WorkoutManager.shared.setVoice(identifier: identifier)
                result(nil)

            case "listVoices":
                result(WorkoutManager.shared.listVoices())

            case "currentVoiceIdentifier":
                result(WorkoutManager.shared.currentVoiceIdentifier())

            case "previewVoice":
                let args = call.arguments as? [String: Any]
                let identifier = args?["identifier"] as? String ?? ""
                let text = args?["text"] as? String ?? "This is a sample of the voice."
                WorkoutManager.shared.previewVoice(identifier: identifier, text: text)
                result(nil)

            case "speak":
                let text = (call.arguments as? [String: Any])?["text"] as? String ?? ""
                WorkoutManager.shared.speak(text: text)
                result(nil)

            case "stopSpeaking":
                WorkoutManager.shared.stopSpeaking()
                result(nil)

            case "setAnnounceInterval":
                let seconds = (call.arguments as? [String: Any])?["seconds"] as? Int ?? 15
                WorkoutManager.shared.setAnnounceInterval(seconds: seconds)
                result(nil)

            case "setSaveToHealth":
                let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? true
                WorkoutManager.shared.setSaveToHealth(enabled)
                result(nil)

            case "setUseImperial":
                let imperial = (call.arguments as? [String: Any])?["imperial"] as? Bool ?? true
                WorkoutManager.shared.setUseImperial(imperial)
                result(nil)

            case "setZones":
                let bounds = (call.arguments as? [String: Any])?["bounds"] as? [Int] ?? []
                WorkoutManager.shared.setZones(bounds)
                result(nil)

            case "setZoneCoaching":
                let args = call.arguments as? [String: Any]
                WorkoutManager.shared.setZoneCoaching(
                    enabled: args?["enabled"] as? Bool ?? false,
                    targetZone: args?["targetZone"] as? Int ?? 0)
                result(nil)

            case "requestNotificationPermission":
                WorkoutManager.shared.requestNotificationPermission { granted in
                    result(granted)
                }

            case "getNotificationStatus":
                WorkoutManager.shared.getNotificationStatus { status in
                    result(status)
                }

            case "excludeFromBackup":
                // Mark a file/directory as excluded from iCloud & iTunes backup
                // so on-device workout health data never leaves the phone. Apple
                // persists the flag; setting it on a directory excludes its whole
                // subtree. Mutating setResourceValues requires a `var` URL.
                guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
                    result(false)
                    return
                }
                var url = URL(fileURLWithPath: path)
                do {
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try url.setResourceValues(values)
                    result(true)
                } catch {
                    result(false)
                }

            case "getAirPodsIcon":
                let pts = (call.arguments as? [String: Any])?["pointSize"] as? CGFloat ?? 120
                let cfg = UIImage.SymbolConfiguration(pointSize: pts, weight: .thin)
                if let sym = UIImage(systemName: "airpods.pro", withConfiguration: cfg) {
                    let tinted = sym.withTintColor(.white, renderingMode: .alwaysOriginal)
                    let renderer = UIGraphicsImageRenderer(size: tinted.size)
                    let png = renderer.pngData { _ in tinted.draw(at: .zero) }
                    result(FlutterStandardTypedData(bytes: png))
                } else {
                    result(nil)
                }

            default:
                // Methods the core doesn't know are offered to the SHB+
                // module's engine (a no-op in the free core).
                if WorkoutManager.shared.handlePlusMethod(call.method, arguments: call.arguments) {
                    result(nil)
                } else {
                    result(FlutterMethodNotImplemented)
                }
            }
        }

        // Event channel: heart rate stream → Flutter
        let hrChannel = FlutterEventChannel(
            name: "steadyheartbeat/heartrate",
            binaryMessenger: messenger
        )
        hrChannel.setStreamHandler(HeartRateStreamHandler())

        // Event channel: status/error events → Flutter
        let statusChannel = FlutterEventChannel(
            name: "steadyheartbeat/status",
            binaryMessenger: messenger
        )
        statusChannel.setStreamHandler(StatusStreamHandler())
    }
}

// MARK: - Stream handlers

class HeartRateStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        WorkoutManager.shared.heartRateEventSink = events
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        WorkoutManager.shared.heartRateEventSink = nil
        return nil
    }
}

class StatusStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        WorkoutManager.shared.statusEventSink = events
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        WorkoutManager.shared.statusEventSink = nil
        return nil
    }
}
