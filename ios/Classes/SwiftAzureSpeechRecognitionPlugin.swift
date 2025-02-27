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

            // Lists to store assessment data (Kotlin 포팅)
            var recognizedWords = [String]()
            var pronWords = [Word]()
            var finalWords = [Word]()
            var fluencyScores = [Double]()
            var prosodyScores = [Double]()
            var durations = [Int64]()

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
                let pronunciationAssessmentResultJson = result.properties?.getPropertyBy(SPXPropertyId.speechServiceResponseJsonResult)
                print("pronunciationAssessmentResultJson: \(pronunciationAssessmentResultJson ?? "(no result)")")

                if result.reason != SPXResultReason.recognizedSpeech {
                    let cancellationDetails = try! SPXCancellationDetails(fromCanceledRecognitionResult: result)
                    print("Cancelled: \(cancellationDetails.description), \(cancellationDetails.errorDetails)\nTaskID: \(taskId)")
                    print("Did you set the speech resource key and region values?")
                    self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: "")
                    self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: "")
                }
                else {
                    // 확장된 평가 처리
                    do {
                        // 결과 텍스트 가져오기
                        let resultText = result.text ?? ""

                        // 발음 평가 결과 가져오기
                        let pronResult = try SPXPronunciationAssessmentResult.from(result)

                        // 초기 점수 저장
                        fluencyScores.append(pronResult.fluencyScore)
                        prosodyScores.append(pronResult.prosodyScore)

                        // JSON 응답을 파싱하여 단어 수준 세부 정보 추출
                        if let jsonString = pronunciationAssessmentResultJson,
                           let jsonData = jsonString.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let nBestArray = json["NBest"] as? [[String: Any]] {

                            // NBest 결과 처리하여 단어 수준 평가 가져오기
                            for nBestItem in nBestArray {
                                if let wordsArray = nBestItem["Words"] as? [[String: Any]] {
                                    var durationSum: Int64 = 0

                                    for wordItem in wordsArray {
                                        if let wordText = wordItem["Word"] as? String {
                                            recognizedWords.append(wordText)

                                            if let duration = wordItem["Duration"] as? Int64 {
                                                durationSum += duration
                                            }

                                            if let pronAssessment = wordItem["PronunciationAssessment"] as? [String: Any],
                                               let errorType = pronAssessment["ErrorType"] as? String,
                                               let accuracyScore = pronAssessment["AccuracyScore"] as? Double {

                                                pronWords.append(Word(
                                                    word: wordText,
                                                    errorType: errorType,
                                                    accuracyScore: accuracyScore
                                                ))
                                            }
                                        }
                                    }
                                    durations.append(durationSum)
                                }
                            }

                            // 참조 텍스트를 단어로 분할하고 구두점 정리
                            let referenceWords = referenceText.lowercased().components(separatedBy: " ").map { word in
                                return word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
                            }

                            // Miscue 감지 처리
                            if enableMiscue {
                                // DifferenceKit 라이브러리 또는 다른 Swift diff 라이브러리를 사용하여 차이 계산
                                // 이 부분은 실제 구현할 Swift 라이브러리에 따라 달라집니다.
                                // 이 예제에서는 간단한 로직으로 대체합니다.

                                // 예: 간단한 워드 비교 로직 (실제 구현에서는 더 강력한 diff 알고리즘 사용)
                                let refSet = Set(referenceWords)
                                let recSet = Set(recognizedWords)

                                // 누락된 단어 (참조에는 있지만 인식되지 않은 단어)
                                let missingWords = refSet.subtracting(recSet)
                                for word in missingWords {
                                    finalWords.append(Word(word: word, errorType: "Omission"))
                                }

                                // 삽입된 단어 (인식되었지만 참조에는 없는 단어)
                                let insertedWords = recSet.subtracting(refSet)
                                for pronWord in pronWords {
                                    if insertedWords.contains(pronWord.word.lowercased()) {
                                        pronWord.errorType = "Insertion"
                                    }
                                    finalWords.append(pronWord)
                                }
                            } else {
                                finalWords.append(contentsOf: pronWords)
                            }

                            // 전체 점수 계산
                            // 1. 정확도 점수 계산
                            var totalAccuracyScore = 0.0
                            var accuracyCount = 0
                            var validCount = 0

                            for word in finalWords {
                                if word.errorType != "Insertion" {
                                    totalAccuracyScore += word.accuracyScore
                                    accuracyCount += 1
                                }

                                if word.errorType == "None" {
                                    validCount += 1
                                }
                            }

                            let accuracyScore = accuracyCount > 0 ? totalAccuracyScore / Double(accuracyCount) : 0.0

                            // 2. 유창성 점수 재계산
                            var fluencyScoreSum = 0.0
                            var durationSum: Int64 = 0

                            for i in 0..<fluencyScores.count {
                                fluencyScoreSum += fluencyScores[i] * Double(durations[i])
                                durationSum += durations[i]
                            }

                            let fluencyScore = durationSum > 0 ? fluencyScoreSum / Double(durationSum) : pronResult.fluencyScore

                            // 3. 운율 점수 재계산
                            let prosodyScore = prosodyScores.count > 0 ? prosodyScores.reduce(0, +) / Double(prosodyScores.count) : pronResult.prosodyScore

                            // 4. 완전성 점수 계산
                            let completenessScore = !referenceWords.isEmpty ? min(Double(validCount) / Double(referenceWords.count) * 100.0, 100.0) : pronResult.completenessScore

                            // 5. 발음 점수 계산
                            let pronScore = accuracyScore * 0.4 + prosodyScore * 0.2 + fluencyScore * 0.2 + completenessScore * 0.2

                            // 최종 점수 로깅
                            print(String(format: "Final scores - Accuracy: %.2f, Prosody: %.2f, Fluency: %.2f, Completeness: %.2f, Pronunciation: %.2f",
                                         accuracyScore, prosodyScore, fluencyScore, completenessScore, pronScore))

                            // 모든 점수가 포함된 수정된 JSON 생성
                            var modifiedJson = json
                            modifiedJson["AccuracyScore"] = accuracyScore
                            modifiedJson["ProsodyScore"] = prosodyScore
                            modifiedJson["FluencyScore"] = fluencyScore
                            modifiedJson["CompletenessScore"] = completenessScore
                            modifiedJson["PronunciationScore"] = pronScore

                            // 단어 수준 평가가 있는 경우 추가
                            if !finalWords.isEmpty {
                                var wordsArray: [[String: Any]] = []

                                for word in finalWords {
                                    wordsArray.append([
                                        "Word": word.word,
                                        "ErrorType": word.errorType,
                                        "AccuracyScore": word.accuracyScore
                                    ])
                                }

                                modifiedJson["Words"] = wordsArray
                            }

                            // 수정된 JSON 문자열 변환
                            let modifiedJsonData = try JSONSerialization.data(withJSONObject: modifiedJson)
                            let modifiedJsonString = String(data: modifiedJsonData, encoding: .utf8) ?? ""

                            self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: resultText)
                            self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: modifiedJsonString)
                        } else {
                            // JSON 파싱 실패 시 원본 결과 반환
                            self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: resultText)
                            self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: pronunciationAssessmentResultJson)
                        }
                    } catch {
                        print("Error processing assessment results: \(error)")
                        self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                        self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: pronunciationAssessmentResultJson)
                    }
                }
            }
            self.simpleRecognitionTasks.removeValue(forKey: taskId)
        }

        simpleRecognitionTasks[taskId] = SimpleRecognitionTask(task: task, isCanceled: false)
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

                if nBestPhonemeCount != nil {
                    pronunciationAssessmentConfig.nbestPhonemeCount = nBestPhonemeCount!
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
                    let pronunciationAssessmentResultJson = result.properties?.getPropertyBy(SPXPropertyId.speechServiceResponseJsonResult)
                    print("pronunciationAssessmentResultJson: \(pronunciationAssessmentResultJson ?? "(no result)")")

                    // 여기서 간단한 처리를 하거나 필요하면 더 복잡한 평가 처리를 추가할 수 있습니다.
                    self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                    self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: pronunciationAssessmentResultJson)
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
}