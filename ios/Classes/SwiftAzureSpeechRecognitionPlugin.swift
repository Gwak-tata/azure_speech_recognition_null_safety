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
            simpleSpeechRecognitionWithAssessment(
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
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // Request access to the microphone
                try audioSession.setCategory(AVAudioSession.Category.record, mode: AVAudioSession.Mode.default, options: AVAudioSession.CategoryOptions.allowBluetooth)
                try audioSession.setActive(true)
                print("Setting custom audio session")
                // Initialize speech recognizer and specify correct subscription key and service region
                try speechConfig = SPXSpeechConfiguration(subscription: speechSubscriptionKey, region: serviceRegion)
            } catch {
                print("error \(error) happened")
                speechConfig = nil
            }
            speechConfig?.speechRecognitionLanguage = lang
            speechConfig?.setPropertyTo(timeoutMs, by: SPXPropertyId.speechSegmentationSilenceTimeoutMs)

            let audioConfig = SPXAudioConfiguration()
            let reco = try! SPXSpeechRecognizer(speechConfiguration: speechConfig!, audioConfiguration: audioConfig)

            reco.addRecognizingEventHandler() {reco, evt in
                if (self.simpleRecognitionTasks[taskId]?.isCanceled ?? false) { // Discard intermediate results if the task was cancelled
                    print("Ignoring partial result. TaskID: \(taskId)")
                }
                else {
                    print("Intermediate result: \(evt.result.text ?? "(no result)")\nTaskID: \(taskId)")
                    self.azureChannel.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                }
            }

            let result = try! reco.recognizeOnce()
            if (Task.isCancelled) {
                print("Ignoring final result. TaskID: \(taskId)")
            } else {
                print("Final result: \(result.text ?? "(no result)")\nReason: \(result.reason.rawValue)\nTaskID: \(taskId)")
                if result.reason != SPXResultReason.recognizedSpeech {
                    let cancellationDetails = try! SPXCancellationDetails(fromCanceledRecognitionResult: result)
                    print("Cancelled: \(cancellationDetails.description), \(cancellationDetails.errorDetails)\nTaskID: \(taskId)")
                    print("Did you set the speech resource key and region values?")
                    self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: "")
                }
                else {
                    self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                }

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

            do {
                let audioSession = AVAudioSession.sharedInstance()
                // Request access to the microphone
                try audioSession.setCategory(AVAudioSession.Category.record, mode: AVAudioSession.Mode.default, options: AVAudioSession.CategoryOptions.allowBluetooth)
                try audioSession.setActive(true)
                print("Setting custom audio session")

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

            let audioConfig = SPXAudioConfiguration()
            let reco = try! SPXSpeechRecognizer(speechConfiguration: speechConfig!, audioConfiguration: audioConfig)
            try! pronunciationAssessmentConfig?.apply(to: reco)

            reco.addRecognizingEventHandler() { reco, evt in
                if (self.simpleRecognitionTasks[taskId]?.isCanceled ?? false) {
                    print("Ignoring partial result. TaskID: \(taskId)")
                }
                else {
                    print("Intermediate result: \(evt.result.text ?? "(no result)")\nTaskID: \(taskId)")
                    self.azureChannel.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                }
            }

            let result = try! reco.recognizeOnce()

            if (Task.isCancelled) {
                print("Ignoring final result. TaskID: \(taskId)")
            } else {
                print("Final result: \(result.text ?? "(no result)")\nReason: \(result.reason.rawValue)\nTaskID: \(taskId)")
                let originalJson = result.properties?.getPropertyBy(SPXPropertyId.speechServiceResponseJsonResult)
                print("originalJson: \(originalJson ?? "(no result)")")

                if result.reason != SPXResultReason.recognizedSpeech {
                    let cancellationDetails = try! SPXCancellationDetails(fromCanceledRecognitionResult: result)
                    print("Cancelled: \(cancellationDetails.description), \(cancellationDetails.errorDetails)\nTaskID: \(taskId)")
                    print("Did you set the speech resource key and region values?")
                    self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: "")
                    self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: "")
                }
                else {
                    // 새로운 PronunciationAssessmentResult 클래스를 사용한 평가 결과 처리
                    do {
                        // PronunciationAssessmentResult 클래스를 이용해 결과 가져오기
                        let pronResult = try SPXPronunciationAssessmentResult.from(result)

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
                                if let contentResult = pronResult.contentAssessmentResult {
                                    // 문법 점수 가져오기
                                    let grammarScore = contentResult.grammarScore
                                    jsonBuilder["GrammarScore"] = grammarScore
                                    scoreLogBuilder += ", Grammar: %.2f"

                                    // 어휘 점수 가져오기
                                    let vocabScore = contentResult.vocabularyScore
                                    jsonBuilder["VocabularyScore"] = vocabScore
                                    scoreLogBuilder += ", Vocabulary: %.2f"

                                    // 주제 점수 가져오기
                                    let topicScore = contentResult.topicScore
                                    jsonBuilder["TopicScore"] = topicScore
                                    scoreLogBuilder += ", Topic: %.2f"
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

                        // 단어 수준 평가 추가 (사용 가능한 경우)
//                        if let words = pronResult.words, !words.isEmpty {
//                            var wordsArray: [[String: Any]] = []
//
//                            for word in words {
//                                var wordDict: [String: Any] = [
//                                    "Word": word.word,
//                                    "AccuracyScore": word.accuracyScore
//                                ]
//
//                                // 오류 유형 기반 ErrorType 추가
//                                let errorType: String
//                                switch word.errorType {
//                                case .none:
//                                    errorType = "None"
//                                case .omission:
//                                    errorType = "Omission"
//                                case .insertion:
//                                    errorType = "Insertion"
//                                case .mispronunciation:
//                                    errorType = "Mispronunciation"
//                                @unknown default:
//                                    errorType = "Unknown"
//                                }
//                                wordDict["ErrorType"] = errorType
//
//                                // 음소 수준 평가 추가 (사용 가능하고 granularity가 Phoneme인 경우)
//                                if granularity == .phoneme, let phonemes = word.phonemes, !phonemes.isEmpty {
//                                    var phonemesArray: [[String: Any]] = []
//
//                                    for phoneme in phonemes {
//                                        phonemesArray.append([
//                                            "Phoneme": phoneme.phoneme,
//                                            "AccuracyScore": phoneme.accuracyScore
//                                        ])
//                                    }
//
//                                    wordDict["Phonemes"] = phonemesArray
//                                }
//
//                                wordsArray.append(wordDict)
//                            }
//
//                            jsonBuilder["Words"] = wordsArray
//                        }

                        // 원본 JSON 변환하여 응답에 포함 (가능한 경우)
//                        if let originalJsonString = originalJson, !originalJsonString.isEmpty {
//                            do {
//                                if let jsonData = originalJsonString.data(using: .utf8),
//                                   let originalJsonObject = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
//
//                                    // NBest 결과 추출 (있는 경우)
//                                    if let nBestArray = originalJsonObject["NBest"] as? [[String: Any]], !nBestArray.isEmpty {
//                                        jsonBuilder["NBest"] = nBestArray
//                                    }
//                                }
//                            } catch {
//                                print("Error parsing original JSON: \(error)")
//                                jsonBuilder["OriginalResponseText"] = originalJsonString
//                            }
//                        }

                        // 항상 원본 JSON을 응답에 포함
                        jsonBuilder["OriginalResponseText"] = originalJson

                        // 최종 JSON을 문자열로 변환
                        let jsonData = try JSONSerialization.data(withJSONObject: jsonBuilder)
                        let assessmentJson = String(data: jsonData, encoding: .utf8) ?? ""

                        self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                        self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: assessmentJson)
                    } catch {
                        print("Error processing assessment results: \(error)")
                        // 오류 발생 시 원본 JSON으로 fallback
                        var fallbackJson: [String: Any] = [:]
                        fallbackJson["OriginalResponseText"] = originalJson ?? ""
                        do {
                            let fallbackJsonData = try JSONSerialization.data(withJSONObject: fallbackJson)
                            let fallbackJsonString = String(data: fallbackJsonData, encoding: .utf8) ?? ""
                            self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                            self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: fallbackJsonString)
                        } catch {
                            self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                            self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: originalJson)
                        }
                    }
                }
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
                self.azureChannel.invokeMethod("speech.onRecognitionStopped", arguments: nil)
                continousSpeechRecognizer = nil
                continousListeningStarted = false
            }
            catch {
                print("Error occurred stopping continous recognition")
            }
        }
        else {
            print("Starting continous recognition")
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // Request access to the microphone
                try audioSession.setCategory(AVAudioSession.Category.record, mode: AVAudioSession.Mode.default, options: AVAudioSession.CategoryOptions.allowBluetooth)
                try audioSession.setActive(true)
                print("Setting custom audio session")

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

                continousSpeechRecognizer = try SPXSpeechRecognizer(speechConfiguration: speechConfig, audioConfiguration: audioConfig)
                try pronunciationAssessmentConfig.apply(to: continousSpeechRecognizer!)

                continousSpeechRecognizer!.addRecognizingEventHandler() {reco, evt in
                    print("intermediate recognition result: \(evt.result.text ?? "(no result)")")
                    self.azureChannel.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                }

                continousSpeechRecognizer!.addRecognizedEventHandler({reco, evt in
                    let result = evt.result
                    print("Final result: \(result.text ?? "(no result)")\nReason: \(result.reason.rawValue)")
                    let originalJson = result.properties?.getPropertyBy(SPXPropertyId.speechServiceResponseJsonResult)
                    print("Original JSON: \(originalJson ?? "(no result)")")

                    if result.reason == SPXResultReason.recognizedSpeech {
                        // 새로운 PronunciationAssessmentResult 클래스를 사용한 평가 결과 처리
                        do {
                            // PronunciationAssessmentResult 클래스를 이용해 결과 가져오기
                            let pronResult = try SPXPronunciationAssessmentResult.from(result)

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

                            self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                            self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: assessmentJson)
                        } catch {
                            print("Error processing assessment results: \(error)")

                            // 오류 발생 시 원본 JSON 전달
                            var fallbackJson: [String: Any] = [:]
                            fallbackJson["OriginalResponseText"] = originalJson ?? ""

                            do {
                                let fallbackJsonData = try JSONSerialization.data(withJSONObject: fallbackJson)
                                let fallbackJsonString = String(data: fallbackJsonData, encoding: .utf8) ?? ""
                                self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                                self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: fallbackJsonString)
                            } catch {
                                self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                                self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: originalJson)
                            }
                        }
                    } else {
                        self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                        self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: "")
                    }
                })

                print("Listening...")
                try continousSpeechRecognizer!.startContinuousRecognition()
                self.azureChannel.invokeMethod("speech.onRecognitionStarted", arguments: nil)
                continousListeningStarted = true
            }
            catch {
                print("An unexpected error occurred: \(error)")
            }
        }
    }

    private func continuousStream(speechSubscriptionKey : String, serviceRegion : String, lang: String) {
        if (continousListeningStarted) {
            print("Stopping continous recognition")
            do {
                try continousSpeechRecognizer!.stopContinuousRecognition()
                self.azureChannel.invokeMethod("speech.onRecognitionStopped", arguments: nil)
                continousSpeechRecognizer = nil
                continousListeningStarted = false
            }
            catch {
                print("Error occurred stopping continous recognition")
            }
        }
        else {
            print("Starting continous recognition")
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // Request access to the microphone
                try audioSession.setCategory(AVAudioSession.Category.record, mode: AVAudioSession.Mode.default, options: AVAudioSession.CategoryOptions.allowBluetooth)
                try audioSession.setActive(true)
                print("Setting custom audio session")
            }
            catch {
                print("An unexpected error occurred")
            }

            let speechConfig = try! SPXSpeechConfiguration(subscription: speechSubscriptionKey, region: serviceRegion)

            speechConfig.speechRecognitionLanguage = lang

            let audioConfig = SPXAudioConfiguration()

            continousSpeechRecognizer = try! SPXSpeechRecognizer(speechConfiguration: speechConfig, audioConfiguration: audioConfig)
            continousSpeechRecognizer!.addRecognizingEventHandler() {reco, evt in
                print("intermediate recognition result: \(evt.result.text ?? "(no result)")")
                self.azureChannel.invokeMethod("speech.onSpeech", arguments: evt.result.text)
            }
            continousSpeechRecognizer!.addRecognizedEventHandler({reco, evt in
                let res = evt.result.text
                print("final result \(res!)")
                self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: res)
            })
            print("Listening...")
            try! continousSpeechRecognizer!.startContinuousRecognition()
            self.azureChannel.invokeMethod("speech.onRecognitionStarted", arguments: nil)
            continousListeningStarted = true
        }
    }

    private func stopContinuousStream(flutterResult: FlutterResult) {
        if (continousListeningStarted) {
            print("Stopping continous recognition")
            do {
                try continousSpeechRecognizer!.stopContinuousRecognition()
                self.azureChannel.invokeMethod("speech.onRecognitionStopped", arguments: nil)
                continousSpeechRecognizer = nil
                continousListeningStarted = false
                flutterResult(true)
            }
            catch {
                print("Error occurred stopping continous recognition")
            }
        }
    }
}