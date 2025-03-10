import Flutter
import UIKit
import MicrosoftCognitiveServicesSpeech
import AVFoundation
// DifferenceKit 라이브러리 사용을 위한 import
import DifferenceKit

@available(iOS 13.0, *)
struct SimpleRecognitionTask {
    var task: Task<Void, Never>
    var isCanceled: Bool
}

@available(iOS 13.0, *)
public class SwiftAzureSpeechRecognitionPlugin: NSObject, FlutterPlugin {
    var azureChannel: FlutterMethodChannel
    var continousListeningStarted: Bool = false
    var continousSpeechRecognizer: SPXSpeechRecognizer? = nil
    var simpleRecognitionTasks: Dictionary<String, SimpleRecognitionTask> = [:]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "azure_speech_recognition", binaryMessenger: registrar.messenger())
        let instance: SwiftAzureSpeechRecognitionPlugin = SwiftAzureSpeechRecognitionPlugin(azureChannel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init(azureChannel: FlutterMethodChannel) {
        self.azureChannel = azureChannel
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? Dictionary<String, Any>
        let speechSubscriptionKey = args?["subscriptionKey"] as? String ?? ""
        let serviceRegion = args?["region"] as? String ?? ""
        let lang = args?["language"] as? String ?? ""
        let timeoutMs = args?["timeout"] as? String ?? ""
        let referenceText = args?["referenceText"] as? String ?? ""
        let phonemeAlphabet = args?["phonemeAlphabet"] as? String ?? "IPA"
        let granularityString = args?["granularity"] as? String ?? "phoneme"
        let enableMiscue = args?["enableMiscue"] as? Bool ?? false
        let nBestPhonemeCount = args?["nBestPhonemeCount"] as? Int
        let topic = args?["topic"] as? String
        var granularity: SPXPronunciationAssessmentGranularity

        if (granularityString == "text") {
            granularity = SPXPronunciationAssessmentGranularity.fullText
        }
        else if (granularityString == "word") {
            granularity = SPXPronunciationAssessmentGranularity.word
        }
        else {
            granularity = SPXPronunciationAssessmentGranularity.phoneme
        }

        if (call.method == "simpleVoice") {
            print("Called simpleVoice")
            simpleSpeechRecognition(speechSubscriptionKey: speechSubscriptionKey, serviceRegion: serviceRegion, lang: lang, timeoutMs: timeoutMs)
            result(true)
        }
        else if (call.method == "simpleVoiceWithAssessment") {
            print("Called simpleVoiceWithAssessment")
            // 마이크 권한 확인 후 실행
            checkMicrophonePermission { granted in
                if granted {
                    self.simpleSpeechRecognitionWithAssessment(
                        referenceText: referenceText,
                        phonemeAlphabet: phonemeAlphabet,
                        granularity: granularity,
                        enableMiscue: enableMiscue,
                        speechSubscriptionKey: speechSubscriptionKey,
                        serviceRegion: serviceRegion,
                        lang: lang,
                        timeoutMs: timeoutMs,
                        nBestPhonemeCount: nBestPhonemeCount,
                        topic: topic)
                } else {
                    DispatchQueue.main.async {
                        self.invokeMethod("speech.onException", arguments: "마이크 접근 권한이 없습니다.")
                    }
                }
            }
            result(true)
        }
        else if (call.method == "isContinuousRecognitionOn") {
            print("Called isContinuousRecognitionOn: \(continousListeningStarted)")
            result(continousListeningStarted)
        }
        else if (call.method == "continuousStream") {
            print("Called continuousStream")
            continuousStream(speechSubscriptionKey: speechSubscriptionKey, serviceRegion: serviceRegion, lang: lang)
            result(true)
        }
        else if (call.method == "continuousStreamWithAssessment") {
            print("Called continuousStreamWithAssessment")
            continuousStreamWithAssessment(
                referenceText: referenceText,
                phonemeAlphabet: phonemeAlphabet,
                granularity: granularity,
                enableMiscue: enableMiscue,
                speechSubscriptionKey: speechSubscriptionKey,
                serviceRegion: serviceRegion,
                lang: lang,
                nBestPhonemeCount: nBestPhonemeCount)
            result(true)
        }
        else if (call.method == "stopContinuousStream") {
            stopContinuousStream(flutterResult: result)
        }
        else {
            result(FlutterMethodNotImplemented)
        }
    }

    // Flutter 채널 호출을 메인 스레드에서 실행하도록 하는 함수
    private func invokeMethod(_ method: String, arguments: Any?) {
        DispatchQueue.main.async {
            self.azureChannel.invokeMethod(method, arguments: arguments)
        }
    }

    // 마이크 권한 확인 함수
    private func checkMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            completion(true)
        case .denied:
            print("마이크 권한이 거부되었습니다.")
            completion(false)
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                completion(granted)
            }
        @unknown default:
            completion(false)
        }
    }

    // 오디오 세션 설정 함수
    private func setupAudioSession() -> Bool {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord,
                                         mode: .spokenAudio,
                                         options: [.allowBluetooth, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("오디오 세션 설정 완료")
            return true
        } catch {
            print("오디오 세션 설정 오류: \(error)")
            return false
        }
    }

    private func cancelActiveSimpleRecognitionTasks() {
        print("Cancelling any active tasks")
        for taskId in simpleRecognitionTasks.keys {
            print("Cancelling task \(taskId)")
            simpleRecognitionTasks[taskId]?.task.cancel()
            simpleRecognitionTasks[taskId]?.isCanceled = true
        }
    }

    private func simpleSpeechRecognition(speechSubscriptionKey: String, serviceRegion: String, lang: String, timeoutMs: String) {
        print("Created new recognition task")
        cancelActiveSimpleRecognitionTasks()
        let taskId = UUID().uuidString;
        let task = Task {
            print("Started recognition with task ID \(taskId)")
            var speechConfig: SPXSpeechConfiguration?

            // 오디오 세션 설정
            if !setupAudioSession() {
                self.invokeMethod("speech.onException", arguments: "오디오 세션 설정에 실패했습니다.")
                return
            }

            do {
                // Initialize speech recognizer and specify correct subscription key and service region
                try speechConfig = SPXSpeechConfiguration(subscription: speechSubscriptionKey, region: serviceRegion)
            } catch {
                print("error \(error) happened")
                speechConfig = nil
                self.invokeMethod("speech.onException", arguments: "Speech 설정 오류: \(error)")
                return
            }

            speechConfig?.speechRecognitionLanguage = lang
            speechConfig?.setPropertyTo(timeoutMs, by: SPXPropertyId.speechSegmentationSilenceTimeoutMs)

            let audioConfig = SPXAudioConfiguration()

            guard let config = speechConfig else {
                self.invokeMethod("speech.onException", arguments: "Speech 설정을 초기화할 수 없습니다.")
                return
            }

            let reco: SPXSpeechRecognizer
            do {
                reco = try SPXSpeechRecognizer(speechConfiguration: config, audioConfiguration: audioConfig)
            } catch {
                self.invokeMethod("speech.onException", arguments: "Speech 인식기 초기화 오류: \(error)")
                return
            }

            reco.addRecognizingEventHandler() {reco, evt in
                if (self.simpleRecognitionTasks[taskId]?.isCanceled ?? false) { // Discard intermediate results if the task was cancelled
                    print("Ignoring partial result. TaskID: \(taskId)")
                }
                else {
                    print("Intermediate result: \(evt.result.text ?? "(no result)")\nTaskID: \(taskId)")
                    self.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                }
            }

            do {
                let result = try reco.recognizeOnce()
                if (Task.isCancelled) {
                    print("Ignoring final result. TaskID: \(taskId)")
                } else {
                    print("Final result: \(result.text ?? "(no result)")\nReason: \(result.reason.rawValue)\nTaskID: \(taskId)")
                    if result.reason != SPXResultReason.recognizedSpeech {
                        do {
                            let cancellationDetails = try SPXCancellationDetails(fromCanceledRecognitionResult: result)
                            print("Cancelled: \(cancellationDetails.description), \(cancellationDetails.errorDetails)\nTaskID: \(taskId)")
                            print("Did you set the speech resource key and region values?")
                        } catch {
                            print("Error getting cancellation details: \(error)")
                        }
                        self.invokeMethod("speech.onFinalResponse", arguments: "")
                    }
                    else {
                        self.invokeMethod("speech.onFinalResponse", arguments: result.text)
                    }
                }
            } catch {
                print("Error in speech recognition: \(error)")
                self.invokeMethod("speech.onException", arguments: "Speech 인식 오류: \(error)")
            }

            self.simpleRecognitionTasks.removeValue(forKey: taskId)
        }
        simpleRecognitionTasks[taskId] = SimpleRecognitionTask(task: task, isCanceled: false)
    }

    // Word 클래스 구현 (코틀린에서 이식)
    class Word {
        var word: String
        var errorType: String
        var accuracyScore: Double = 0.0
        var duration: Double = 0.0

        init(word: String, errorType: String) {
            self.word = word
            self.errorType = errorType
        }

        init(word: String, errorType: String, accuracyScore: Double) {
            self.word = word
            self.errorType = errorType
            self.accuracyScore = accuracyScore
        }

        init(word: String, errorType: String, accuracyScore: Double, duration: Double) {
            self.word = word
            self.errorType = errorType
            self.accuracyScore = accuracyScore
            self.duration = duration
        }
    }

    private func simpleSpeechRecognitionWithAssessment(
            referenceText: String,
            phonemeAlphabet: String,
            granularity: SPXPronunciationAssessmentGranularity,
            enableMiscue: Bool,
            speechSubscriptionKey: String,
            serviceRegion: String,
            lang: String,
            timeoutMs: String,
            nBestPhonemeCount: Int?,
            topic: String?) {

            print("Created new recognition task with assessment")
            cancelActiveSimpleRecognitionTasks()
            let taskId = UUID().uuidString

            let task = Task {
                print("Started recognition with assessment, task ID \(taskId)")
                var speechConfig: SPXSpeechConfiguration?
                var pronunciationAssessmentConfig: SPXPronunciationAssessmentConfiguration?

                // 오디오 세션 설정
                if !setupAudioSession() {
                    self.invokeMethod("speech.onException", arguments: "오디오 세션 설정에 실패했습니다.")
                    return
                }

                do {
                    // Initialize speech recognizer and specify correct subscription key and service region
                    try speechConfig = SPXSpeechConfiguration(subscription: speechSubscriptionKey, region: serviceRegion)
                    try pronunciationAssessmentConfig = SPXPronunciationAssessmentConfiguration.init(
                        referenceText,
                        gradingSystem: SPXPronunciationAssessmentGradingSystem.hundredMark,
                        granularity: granularity,
                        enableMiscue: enableMiscue)
                } catch {
                    print("Error occurred: \(error)")
                    speechConfig = nil
                    self.invokeMethod("speech.onException", arguments: "Speech 설정 오류: \(error)")
                    return
                }

                pronunciationAssessmentConfig?.enableProsodyAssessment()
                pronunciationAssessmentConfig?.phonemeAlphabet = phonemeAlphabet

                if let topic = topic {
                    pronunciationAssessmentConfig?.enableContentAssessment(withTopic: topic)
                }

                if let nBestPhonemeCount = nBestPhonemeCount {
                    pronunciationAssessmentConfig?.nbestPhonemeCount = nBestPhonemeCount
                }

                speechConfig?.speechRecognitionLanguage = lang
                speechConfig?.setPropertyTo(timeoutMs, by: SPXPropertyId.speechSegmentationSilenceTimeoutMs)

                guard let config = speechConfig, let pronConfig = pronunciationAssessmentConfig else {
                    self.invokeMethod("speech.onException", arguments: "Speech 설정을 초기화할 수 없습니다.")
                    return
                }

                let audioConfig = SPXAudioConfiguration()

                let reco: SPXSpeechRecognizer
                do {
                    reco = try SPXSpeechRecognizer(speechConfiguration: config, audioConfiguration: audioConfig)
                    try pronConfig.apply(to: reco)
                } catch {
                    self.invokeMethod("speech.onException", arguments: "Speech 인식기 초기화 오류: \(error)")
                    return
                }

                reco.addRecognizingEventHandler() { reco, evt in
                    if (self.simpleRecognitionTasks[taskId]?.isCanceled ?? false) {
                        print("Ignoring partial result. TaskID: \(taskId)")
                    }
                    else {
                        print("Intermediate result: \(evt.result.text ?? "(no result)")\nTaskID: \(taskId)")
                        self.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                    }
                }

                do {
                    let result = try reco.recognizeOnce()

                    if (Task.isCancelled) {
                        print("Ignoring final result. TaskID: \(taskId)")
                    } else {
                        print("Final result: \(result.text ?? "(no result)")\nReason: \(result.reason.rawValue)\nTaskID: \(taskId)")
                        let originalJson = result.properties?.getPropertyBy(SPXPropertyId.speechServiceResponseJsonResult)
                        print("originalJson: \(originalJson ?? "(no result)")")

                        if result.reason != SPXResultReason.recognizedSpeech {
                            do {
                                let cancellationDetails = try SPXCancellationDetails(fromCanceledRecognitionResult: result)
                                print("Cancelled: \(cancellationDetails.description), \(cancellationDetails.errorDetails)\nTaskID: \(taskId)")
                                print("Did you set the speech resource key and region values?")
                            } catch {
                                print("Error getting cancellation details: \(error)")
                            }
                            self.invokeMethod("speech.onFinalResponse", arguments: "")
                            self.invokeMethod("speech.onAssessmentResult", arguments: "")
                        }
                        else {
                            // 새로운 PronunciationAssessmentResult 클래스를 사용한 평가 결과 처리
                            do {
                                // PronunciationAssessmentResult 클래스를 이용해 결과 가져오기
                                if let pronResult = SPXPronunciationAssessmentResult(result) {
                                    // PronunciationAssessmentResult에서 직접 모든 점수 추출
                                    let accuracyScore = pronResult.accuracyScore
                                    let fluencyScore = pronResult.fluencyScore
                                    let completenessScore = pronResult.completenessScore
                                    let prosodyScore = pronResult.prosodyScore
                                    let pronunciationScore = pronResult.pronunciationScore

                                    // 로그 메시지를 위한 StringBuilder
                                    var scoreLogBuilder = "Scores - Accuracy: %.2f, Prosody: %.2f, Fluency: %.2f, Completeness: %.2f, Pronunciation: %.2f"

                                    // 점수가 포함된 JSON 객체 생성
                                    var jsonBuilder: [String: Any] = [
                                        "AccuracyScore": accuracyScore,
                                        "ProsodyScore": prosodyScore,
                                        "FluencyScore": fluencyScore,
                                        "CompletenessScore": completenessScore,
                                        "PronunciationScore": pronunciationScore
                                    ]

                                    // topic이 제공되었을 경우 ContentAssessment 결과 가져오기
                                    if let topic = topic {
                                        do {
                                            // ContentAssessmentResult 가져오기 시도
                                            if let contentJsonString = result.properties?.getPropertyBy(SPXPropertyId.speechServiceResponseJsonResult),
                                               let contentJsonData = contentJsonString.data(using: .utf8),
                                               let contentJson = try? JSONSerialization.jsonObject(with: contentJsonData) as? [String: Any],
                                               let nBestArray = contentJson["NBest"] as? [[String: Any]],
                                               let firstNBest = nBestArray.first,
                                               let contentAssessment = firstNBest["ContentAssessment"] as? [String: Any] {

                                                // 문법 점수 가져오기
                                                if let grammarScore = contentAssessment["GrammarScore"] as? Double {
                                                    jsonBuilder["GrammarScore"] = grammarScore
                                                    scoreLogBuilder += ", Grammar: %.2f"
                                                }

                                                // 어휘 점수 가져오기
                                                if let vocabScore = contentAssessment["VocabularyScore"] as? Double {
                                                    jsonBuilder["VocabularyScore"] = vocabScore
                                                    scoreLogBuilder += ", Vocabulary: %.2f"
                                                }

                                                // 주제 점수 가져오기
                                                if let topicScore = contentAssessment["TopicScore"] as? Double {
                                                    jsonBuilder["TopicScore"] = topicScore
                                                    scoreLogBuilder += ", Topic: %.2f"
                                                }
                                            }
                                        } catch {
                                            print("Error getting content assessment result: \(error)")
                                        }
                                    }

                                    // 모든 점수 로깅
                                    print(String(format: scoreLogBuilder,
                                                accuracyScore,
                                                prosodyScore,
                                                fluencyScore,
                                                completenessScore,
                                                pronunciationScore))

                                    // 항상 원본 JSON을 응답에 포함
                                    jsonBuilder["OriginalResponseText"] = originalJson

                                    // 최종 JSON을 문자열로 변환
                                    let jsonData = try JSONSerialization.data(withJSONObject: jsonBuilder)
                                    let assessmentJson = String(data: jsonData, encoding: .utf8) ?? ""

                                    self.invokeMethod("speech.onFinalResponse", arguments: result.text)
                                    self.invokeMethod("speech.onAssessmentResult", arguments: assessmentJson)
                                } else {
                                    // pronResult가 nil인 경우 직접 JSON 파싱으로 대체
                                    var jsonBuilder: [String: Any] = [:]
                                    if let originalJsonString = originalJson,
                                       let jsonData = originalJsonString.data(using: .utf8),
                                       let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                                       let nBestArray = jsonObject["NBest"] as? [[String: Any]],
                                       let firstNBest = nBestArray.first,
                                       let pronAssessment = firstNBest["PronunciationAssessment"] as? [String: Any] {

                                        if let accuracyScore = pronAssessment["AccuracyScore"] as? Double {
                                            jsonBuilder["AccuracyScore"] = accuracyScore
                                        }
                                        if let fluencyScore = pronAssessment["FluencyScore"] as? Double {
                                            jsonBuilder["FluencyScore"] = fluencyScore
                                        }
                                        if let completenessScore = pronAssessment["CompletenessScore"] as? Double {
                                            jsonBuilder["CompletenessScore"] = completenessScore
                                        }
                                        if let prosodyScore = pronAssessment["ProsodyScore"] as? Double {
                                            jsonBuilder["ProsodyScore"] = prosodyScore
                                        }
                                        if let pronScore = pronAssessment["PronScore"] as? Double {
                                            jsonBuilder["PronunciationScore"] = pronScore
                                        }
                                    }

                                    // 항상 원본 JSON을 응답에 포함
                                    jsonBuilder["OriginalResponseText"] = originalJson

                                    // 최종 JSON을 문자열로 변환
                                    let jsonData = try JSONSerialization.data(withJSONObject: jsonBuilder)
                                    let assessmentJson = String(data: jsonData, encoding: .utf8) ?? ""

                                    self.invokeMethod("speech.onFinalResponse", arguments: result.text)
                                    self.invokeMethod("speech.onAssessmentResult", arguments: assessmentJson)
                                }
                            } catch {
                                print("Error processing assessment results: \(error)")
                                // 오류 발생 시 원본 JSON으로 fallback
                                var fallbackJson: [String: Any] = [:]
                                fallbackJson["OriginalResponseText"] = originalJson ?? ""

                                do {
                                    let fallbackJsonData = try JSONSerialization.data(withJSONObject: fallbackJson)
                                    let fallbackJsonString = String(data: fallbackJsonData, encoding: .utf8) ?? ""
                                    self.invokeMethod("speech.onFinalResponse", arguments: result.text)
                                    self.invokeMethod("speech.onAssessmentResult", arguments: fallbackJsonString)
                                } catch {
                                    self.invokeMethod("speech.onFinalResponse", arguments: result.text)
                                    self.invokeMethod("speech.onAssessmentResult", arguments: originalJson)
                                }
                            }
                        }
                    }
                } catch {
                    print("Error in speech recognition: \(error)")
                    self.invokeMethod("speech.onException", arguments: "Speech 인식 오류: \(error)")
                }

                self.simpleRecognitionTasks.removeValue(forKey: taskId)
            }

            simpleRecognitionTasks[taskId] = SimpleRecognitionTask(task: task, isCanceled: false)
        }

    private func continuousStreamWithAssessment(
        referenceText: String,
        phonemeAlphabet: String,
        granularity: SPXPronunciationAssessmentGranularity,
        enableMiscue: Bool,
        speechSubscriptionKey: String,
        serviceRegion: String,
        lang: String,
        nBestPhonemeCount: Int?) {

        print("Continuous recognition started: \(continousListeningStarted)")

        if (continousListeningStarted) {
            print("Stopping continous recognition")
            do {
                try continousSpeechRecognizer!.stopContinuousRecognition()
                self.invokeMethod("speech.onRecognitionStopped", arguments: nil)
                continousSpeechRecognizer = nil
                continousListeningStarted = false
            }
            catch {
                print("Error occurred stopping continous recognition")
            }
        }
        else {
            print("Starting continous recognition")

            // 권한 확인 후 진행
            checkMicrophonePermission { granted in
                if !granted {
                    self.invokeMethod("speech.onException", arguments: "마이크 접근 권한이 없습니다.")
                    return
                }

                // 오디오 세션 설정
                if !self.setupAudioSession() {
                    self.invokeMethod("speech.onException", arguments: "오디오 세션 설정에 실패했습니다.")
                    return
                }

                do {
                    let speechConfig = try SPXSpeechConfiguration(subscription: speechSubscriptionKey, region: serviceRegion)
                    speechConfig.speechRecognitionLanguage = lang

                    let pronunciationAssessmentConfig = try SPXPronunciationAssessmentConfiguration.init(
                        referenceText,
                        gradingSystem: SPXPronunciationAssessmentGradingSystem.hundredMark,
                        granularity: granularity,
                        enableMiscue: enableMiscue)

                    pronunciationAssessmentConfig.phonemeAlphabet = phonemeAlphabet
                    pronunciationAssessmentConfig.enableProsodyAssessment()

                    if let nBestPhonemeCount = nBestPhonemeCount {
                        pronunciationAssessmentConfig.nbestPhonemeCount = nBestPhonemeCount
                    }

                    let audioConfig = SPXAudioConfiguration()

                    self.continousSpeechRecognizer = try SPXSpeechRecognizer(speechConfiguration: speechConfig, audioConfiguration: audioConfig)
                    try pronunciationAssessmentConfig.apply(to: self.continousSpeechRecognizer!)

                    self.continousSpeechRecognizer!.addRecognizingEventHandler() {reco, evt in
                        print("intermediate recognition result: \(evt.result.text ?? "(no result)")")
                        self.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                    }

                    self.continousSpeechRecognizer!.addRecognizedEventHandler({reco, evt in
                        let result = evt.result
                        print("Final result: \(result.text ?? "(no result)")\nReason: \(result.reason.rawValue)")
                        let originalJson = result.properties?.getPropertyBy(SPXPropertyId.speechServiceResponseJsonResult)
                        print("Original JSON: \(originalJson ?? "(no result)")")

                        if result.reason == SPXResultReason.recognizedSpeech {
                            // 새로운 PronunciationAssessmentResult 클래스를 사용한 평가 결과 처리
                            do {
                                if let pronResult = SPXPronunciationAssessmentResult(result) {
                                    // 기본 점수 추출
                                    var jsonBuilder: [String: Any] = [
                                        "AccuracyScore": pronResult.accuracyScore,
                                        "ProsodyScore": pronResult.prosodyScore,
                                        "FluencyScore": pronResult.fluencyScore,
                                        "CompletenessScore": pronResult.completenessScore,
                                        "PronunciationScore": pronResult.pronunciationScore
                                    ]

                                    // 항상 원본 JSON 포함
                                    jsonBuilder["OriginalResponseText"] = originalJson

                                    // JSON을 문자열로 변환
                                    let jsonData = try JSONSerialization.data(withJSONObject: jsonBuilder)
                                    let assessmentJson = String(data: jsonData, encoding: .utf8) ?? originalJson ?? ""

                                    self.invokeMethod("speech.onFinalResponse", arguments: result.text)
                                    self.invokeMethod("speech.onAssessmentResult", arguments: assessmentJson)
                                } else {
                                    // pronResult가 nil인 경우 직접 JSON 파싱으로 대체
                                    var jsonBuilder: [String: Any] = [:]
                                    if let originalJsonString = originalJson,
                                       let jsonData = originalJsonString.data(using: .utf8),
                                       let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                                       let nBestArray = jsonObject["NBest"] as? [[String: Any]],
                                       let firstNBest = nBestArray.first,
                                       let pronAssessment = firstNBest["PronunciationAssessment"] as? [String: Any] {

                                        if let accuracyScore = pronAssessment["AccuracyScore"] as? Double {
                                            jsonBuilder["AccuracyScore"] = accuracyScore
                                        }
                                        if let fluencyScore = pronAssessment["FluencyScore"] as? Double {
                                            jsonBuilder["FluencyScore"] = fluencyScore
                                        }
                                        if let completenessScore = pronAssessment["CompletenessScore"] as? Double {
                                            jsonBuilder["CompletenessScore"] = completenessScore
                                        }
                                        if let prosodyScore = pronAssessment["ProsodyScore"] as? Double {
                                            jsonBuilder["ProsodyScore"] = prosodyScore
                                        }
                                        if let pronScore = pronAssessment["PronScore"] as? Double {
                                            jsonBuilder["PronunciationScore"] = pronScore
                                        }
                                    }

                                    // 항상 원본 JSON을 응답에 포함
                                    jsonBuilder["OriginalResponseText"] = originalJson

                                    // 최종 JSON을 문자열로 변환
                                    let jsonData = try JSONSerialization.data(withJSONObject: jsonBuilder)
                                    let fallbackJsonString = String(data: jsonData, encoding: .utf8) ?? ""

                                    self.invokeMethod("speech.onFinalResponse", arguments: result.text)
                                    self.invokeMethod("speech.onAssessmentResult", arguments: fallbackJsonString)
                                }
                            } catch {
                                print("Error processing assessment results: \(error)")

                                // 오류 발생 시 원본 JSON 전달
                                var fallbackJson: [String: Any] = [:]
                                fallbackJson["OriginalResponseText"] = originalJson ?? ""

                                do {
                                    let fallbackJsonData = try JSONSerialization.data(withJSONObject: fallbackJson)
                                    let fallbackJsonString = String(data: fallbackJsonData, encoding: .utf8) ?? ""
                                    self.invokeMethod("speech.onFinalResponse", arguments: result.text)
                                    self.invokeMethod("speech.onAssessmentResult", arguments: fallbackJsonString)
                                } catch {
                                    self.invokeMethod("speech.onFinalResponse", arguments: result.text)
                                    self.invokeMethod("speech.onAssessmentResult", arguments: originalJson)
                                }
                            }
                        } else {
                            self.invokeMethod("speech.onFinalResponse", arguments: result.text)
                            self.invokeMethod("speech.onAssessmentResult", arguments: "")
                        }
                    })

                    print("Listening...")
                    try self.continousSpeechRecognizer!.startContinuousRecognition()
                    self.invokeMethod("speech.onRecognitionStarted", arguments: nil)
                    self.continousListeningStarted = true
                }
                catch {
                    print("An unexpected error occurred: \(error)")
                    self.invokeMethod("speech.onException", arguments: "연속 인식 시작 오류: \(error)")
                }
            }
        }
    }

    private func continuousStream(speechSubscriptionKey : String, serviceRegion : String, lang: String) {
        if (continousListeningStarted) {
            print("Stopping continous recognition")
            do {
                try continousSpeechRecognizer!.stopContinuousRecognition()
                self.invokeMethod("speech.onRecognitionStopped", arguments: nil)
                continousSpeechRecognizer = nil
                continousListeningStarted = false
            }
            catch {
                print("Error occurred stopping continous recognition")
            }
        }
        else {
            print("Starting continous recognition")

            // 권한 확인 후 진행
            checkMicrophonePermission { granted in
                if !granted {
                    self.invokeMethod("speech.onException", arguments: "마이크 접근 권한이 없습니다.")
                    return
                }

                // 오디오 세션 설정
                if !self.setupAudioSession() {
                    self.invokeMethod("speech.onException", arguments: "오디오 세션 설정에 실패했습니다.")
                    return
                }

                do {
                    let speechConfig = try SPXSpeechConfiguration(subscription: speechSubscriptionKey, region: serviceRegion)
                    speechConfig.speechRecognitionLanguage = lang

                    let audioConfig = SPXAudioConfiguration()

                    self.continousSpeechRecognizer = try SPXSpeechRecognizer(speechConfiguration: speechConfig, audioConfiguration: audioConfig)
                    self.continousSpeechRecognizer!.addRecognizingEventHandler() {reco, evt in
                        print("intermediate recognition result: \(evt.result.text ?? "(no result)")")
                        self.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                    }
                    self.continousSpeechRecognizer!.addRecognizedEventHandler({reco, evt in
                        let res = evt.result.text
                        print("final result \(res ?? "")")
                        self.invokeMethod("speech.onFinalResponse", arguments: res)
                    })
                    print("Listening...")
                    try self.continousSpeechRecognizer!.startContinuousRecognition()
                    self.invokeMethod("speech.onRecognitionStarted", arguments: nil)
                    self.continousListeningStarted = true
                }
                catch {
                    print("An unexpected error occurred: \(error)")
                    self.invokeMethod("speech.onException", arguments: "연속 인식 시작 오류: \(error)")
                }
            }
        }
    }

    private func stopContinuousStream(flutterResult: FlutterResult) {
        if (continousListeningStarted) {
            print("Stopping continous recognition")
            do {
                try continousSpeechRecognizer!.stopContinuousRecognition()
                self.invokeMethod("speech.onRecognitionStopped", arguments: nil)
                continousSpeechRecognizer = nil
                continousListeningStarted = false
                flutterResult(true)
            }
            catch {
                print("Error occurred stopping continous recognition: \(error)")
                flutterResult(FlutterError(code: "STOP_ERROR", message: "Error stopping continuous recognition", details: error.localizedDescription))
            }
        } else {
            flutterResult(true) // 이미 중지된 상태
        }
    }
}