package com.jjordanoc.azure_speech_recognition_null_safety

//import androidx.core.app.ActivityCompat;

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.NonNull
import com.microsoft.cognitiveservices.speech.*
import com.microsoft.cognitiveservices.speech.audio.AudioConfig
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry.Registrar
import java.io.StringReader
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import javax.json.Json
import javax.json.JsonObject
import com.github.difflib.DiffUtils
import com.github.difflib.patch.DeltaType

/** AzureSpeechRecognitionPlugin */
class AzureSpeechRecognitionPlugin : FlutterPlugin, Activity(), MethodCallHandler {
    private lateinit var azureChannel: MethodChannel
    private lateinit var handler: Handler
    var continuousListeningStarted: Boolean = false
    lateinit var reco: SpeechRecognizer
    lateinit var task_global: Future<SpeechRecognitionResult>

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        azureChannel = MethodChannel(
            flutterPluginBinding.getFlutterEngine().getDartExecutor(), "azure_speech_recognition"
        )
        azureChannel.setMethodCallHandler(this)

    }

    init {
        fun registerWith(registrar: Registrar) {
            val channel = MethodChannel(registrar.messenger(), "azure_speech_recognition")

            this.azureChannel = MethodChannel(registrar.messenger(), "azure_speech_recognition")
            this.azureChannel.setMethodCallHandler(this)
        }

        handler = Handler(Looper.getMainLooper())
    }


    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        val speechSubscriptionKey: String = call.argument("subscriptionKey") ?: ""
        val serviceRegion: String = call.argument("region") ?: ""
        val lang: String = call.argument("language") ?: ""
        val timeoutMs: String = call.argument("timeout") ?: ""
        val referenceText: String = call.argument("referenceText") ?: ""
        val phonemeAlphabet: String = call.argument("phonemeAlphabet") ?: "IPA"
        val granularityString: String = call.argument("granularity") ?: "phoneme"
        val enableMiscue: Boolean = call.argument("enableMiscue") ?: false
        val nBestPhonemeCount: Int? = call.argument("nBestPhonemeCount") ?: null
        val granularity: PronunciationAssessmentGranularity
        val topic: String? = call.argument("topic") ?: null
        when (granularityString) {
            "text" -> {
                granularity = PronunciationAssessmentGranularity.FullText
            }

            "word" -> {
                granularity = PronunciationAssessmentGranularity.Word
            }

            else -> {
                granularity = PronunciationAssessmentGranularity.Phoneme
            }
        }
        when (call.method) {
            "simpleVoice" -> {
                simpleSpeechRecognition(speechSubscriptionKey, serviceRegion, lang, timeoutMs)
                result.success(true)
            }

            "simpleVoiceWithAssessment" -> {
                simpleSpeechRecognitionWithAssessment(
                    referenceText,
                    phonemeAlphabet,
                    granularity,
                    enableMiscue,
                    speechSubscriptionKey,
                    serviceRegion,
                    lang,
                    timeoutMs,
                    nBestPhonemeCount,
                    topic,
                )
                result.success(true)
            }

            "isContinuousRecognitionOn" -> {
                result.success(continuousListeningStarted)
            }

            "continuousStream" -> {
                micStreamContinuously(speechSubscriptionKey, serviceRegion, lang)
                result.success(true)
            }

            "continuousStreamWithAssessment" -> {
                micStreamContinuouslyWithAssessment(
                    referenceText,
                    phonemeAlphabet,
                    granularity,
                    enableMiscue,
                    speechSubscriptionKey,
                    serviceRegion,
                    lang,
                    nBestPhonemeCount,
                )
                result.success(true)
            }

            "stopContinuousStream" -> {
                stopContinuousMicStream(result)
            }

            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        azureChannel.setMethodCallHandler(null)
    }

    private fun simpleSpeechRecognition(
        speechSubscriptionKey: String, serviceRegion: String, lang: String, timeoutMs: String
    ) {
        val logTag: String = "simpleVoice"
        try {

            val audioInput: AudioConfig = AudioConfig.fromDefaultMicrophoneInput()

            val config: SpeechConfig =
                SpeechConfig.fromSubscription(speechSubscriptionKey, serviceRegion)

            config.speechRecognitionLanguage = lang
            config.setProperty(PropertyId.Speech_SegmentationSilenceTimeoutMs, timeoutMs)

            val reco: SpeechRecognizer = SpeechRecognizer(config, audioInput)

            val task: Future<SpeechRecognitionResult> = reco.recognizeOnceAsync()

            task_global = task

            invokeMethod("speech.onRecognitionStarted", null)

            reco.recognizing.addEventListener { _, speechRecognitionResultEventArgs ->
                val s = speechRecognitionResultEventArgs.result.text
                Log.i(logTag, "Intermediate result received: " + s)
                if (task_global === task) {
                    invokeMethod("speech.onSpeech", s)
                }
            }

            setOnTaskCompletedListener(task) { result ->
                val s = result.text
                Log.i(logTag, "Recognizer returned: " + s)
                if (task_global === task) {
                    if (result.reason == ResultReason.RecognizedSpeech) {
                        invokeMethod("speech.onFinalResponse", s)
                    } else {
                        invokeMethod("speech.onFinalResponse", "")
                    }
                }
                reco.close()
            }

        } catch (exec: Exception) {
            Log.i(logTag, "ERROR")
            assert(false)
            invokeMethod("speech.onException", "Exception: " + exec.message)

        }
    }

    private fun simpleSpeechRecognitionWithAssessment(
        referenceText: String,
        phonemeAlphabet: String,
        granularity: PronunciationAssessmentGranularity,
        enableMiscue: Boolean,
        speechSubscriptionKey: String,
        serviceRegion: String,
        lang: String,
        timeoutMs: String,
        nBestPhonemeCount: Int?,
        topic: String?,
    ) {
        val logTag: String = "simpleVoiceWithAssessment"

        try {
            val audioInput: AudioConfig = AudioConfig.fromDefaultMicrophoneInput()

            val config: SpeechConfig =
                SpeechConfig.fromSubscription(speechSubscriptionKey, serviceRegion)
            config.speechRecognitionLanguage = lang
            config.setProperty(PropertyId.Speech_SegmentationSilenceTimeoutMs, timeoutMs)

            val pronunciationAssessmentConfig: PronunciationAssessmentConfig =
                PronunciationAssessmentConfig(
                    referenceText,
                    PronunciationAssessmentGradingSystem.HundredMark,
                    granularity,
                    enableMiscue
                )
            pronunciationAssessmentConfig.enableProsodyAssessment()
            pronunciationAssessmentConfig.setPhonemeAlphabet(phonemeAlphabet)

            if (topic != null) {
                pronunciationAssessmentConfig.enableContentAssessmentWithTopic(topic)
            }

            if (nBestPhonemeCount != null) {
                pronunciationAssessmentConfig.setNBestPhonemeCount(nBestPhonemeCount)
            }

            Log.i(logTag, pronunciationAssessmentConfig.toJson())

            val reco: SpeechRecognizer = SpeechRecognizer(config, audioInput)
            pronunciationAssessmentConfig.applyTo(reco)

            val task: Future<SpeechRecognitionResult> = reco.recognizeOnceAsync()
            task_global = task

            invokeMethod("speech.onRecognitionStarted", null)

            reco.recognizing.addEventListener { _, speechRecognitionResultEventArgs ->
                val s = speechRecognitionResultEventArgs.result.text
                Log.i(logTag, "Intermediate result received: " + s)
                if (task_global === task) {
                    invokeMethod("speech.onSpeech", s)
                }
            }

            setOnTaskCompletedListener(task) { result ->
                val s = result.text
                val originalJson = result.properties.getProperty(PropertyId.SpeechServiceResponse_JsonResult)
                Log.i(logTag, "Final result: $s\nReason: ${result.reason}")
                Log.i(logTag, "Original JSON: $originalJson")

                if (task_global === task) {
                    if (result.reason == ResultReason.RecognizedSpeech) {
                        try {
                            // Use the new PronunciationAssessmentResult class to get assessment results
                            val pronResult = PronunciationAssessmentResult.fromResult(result)

                            // Extract all scores directly from the PronunciationAssessmentResult
                            val accuracyScore = pronResult.getAccuracyScore()
                            val fluencyScore = pronResult.getFluencyScore()
                            val completenessScore = pronResult.getCompletenessScore()
                            val prosodyScore = pronResult.getProsodyScore()
                            val pronunciationScore = pronResult.getPronunciationScore()

                            // StringBuilder for log message
                            val scoreLogBuilder = StringBuilder("Scores - Accuracy: %.2f, Prosody: %.2f, Fluency: %.2f, " +
                                    "Completeness: %.2f, Pronunciation: %.2f")

                            // Create a JSON object with the scores
                            val jsonObjectBuilder = javax.json.Json.createObjectBuilder()
                                .add("AccuracyScore", accuracyScore)
                                .add("ProsodyScore", prosodyScore)
                                .add("FluencyScore", fluencyScore)
                                .add("CompletenessScore", completenessScore)
                                .add("PronunciationScore", pronunciationScore)

                            // Get content assessment scores if topic was provided
                            if (topic != null) {
                                try {
                                    // Try to get the content assessment result
                                    val getContentMethod = pronResult.javaClass.getMethod("getContentAssessmentResult")
                                    if (getContentMethod != null) {
                                        val contentResult = getContentMethod.invoke(pronResult)

                                        if (contentResult != null) {
                                            val contentClass = contentResult.javaClass

                                            // Get grammar score
                                            try {
                                                val getGrammarMethod = contentClass.getMethod("getGrammarScore")
                                                val grammarScore = (getGrammarMethod.invoke(contentResult) as? Double) ?: 0.0
                                                jsonObjectBuilder.add("GrammarScore", grammarScore)
                                                scoreLogBuilder.append(", Grammar: %.2f")
                                            } catch (e: Exception) {
                                                Log.e(logTag, "Error getting grammar score: ${e.message}", e)
                                            }

                                            // Get vocabulary score
                                            try {
                                                val getVocabMethod = contentClass.getMethod("getVocabularyScore")
                                                val vocabScore = (getVocabMethod.invoke(contentResult) as? Double) ?: 0.0
                                                jsonObjectBuilder.add("VocabularyScore", vocabScore)
                                                scoreLogBuilder.append(", Vocabulary: %.2f")
                                            } catch (e: Exception) {
                                                Log.e(logTag, "Error getting vocabulary score: ${e.message}", e)
                                            }

                                            // Get topic score
                                            try {
                                                val getTopicMethod = contentClass.getMethod("getTopicScore")
                                                val topicScore = (getTopicMethod.invoke(contentResult) as? Double) ?: 0.0
                                                jsonObjectBuilder.add("TopicScore", topicScore)
                                                scoreLogBuilder.append(", Topic: %.2f")
                                            } catch (e: Exception) {
                                                Log.e(logTag, "Error getting topic score: ${e.message}", e)
                                            }
                                        }
                                    }
                                } catch (e: Exception) {
                                    Log.e(logTag, "Error getting content assessment result: ${e.message}", e)
                                }
                            }

                            // Log all the scores
                            Log.i(logTag, String.format(
                                scoreLogBuilder.toString(),
                                accuracyScore,
                                prosodyScore,
                                fluencyScore,
                                completenessScore,
                                pronunciationScore
                                // Content assessment scores would go here if they were included in the log message
                            ))

                            // Add word-level assessment if available
//                            try {
//                                val wordsMethod = pronResult.javaClass.getMethod("getWords")
//                                val words = wordsMethod.invoke(pronResult) as? List<*>
//
//                                if (words != null && words.isNotEmpty()) {
//                                    val wordsArrayBuilder = javax.json.Json.createArrayBuilder()
//
//                                    for (wordObj in words) {
//                                        if (wordObj != null) {
//                                            val wordBuilder = javax.json.Json.createObjectBuilder()
//
//                                            // Get word text using reflection
//                                            val getWordMethod = wordObj.javaClass.getMethod("getWord")
//                                            val wordText = getWordMethod.invoke(wordObj) as? String
//                                            wordBuilder.add("Word", wordText ?: "")
//
//                                            // Get accuracy score using reflection
//                                            val getAccuracyMethod = wordObj.javaClass.getMethod("getAccuracyScore")
//                                            val accuracyScoreValue = (getAccuracyMethod.invoke(wordObj) as? Double) ?: 0.0
//                                            wordBuilder.add("AccuracyScore", accuracyScoreValue)
//
//                                            // Try to get error type if available
//                                            try {
//                                                val getErrorTypeMethod = wordObj.javaClass.getMethod("getErrorType")
//                                                val errorTypeObj = getErrorTypeMethod.invoke(wordObj)
//                                                val errorType = errorTypeObj?.toString() ?: "Unknown"
//                                                wordBuilder.add("ErrorType", errorType)
//                                            } catch (e: Exception) {
//                                                // If error type method isn't available, use a default
//                                                wordBuilder.add("ErrorType", "Unknown")
//                                            }
//
//                                            wordsArrayBuilder.add(wordBuilder)
//                                        }
//                                    }
//
//                                    jsonObjectBuilder.add("Words", wordsArrayBuilder)
//                                }
//                            } catch (e: Exception) {
//                                Log.e(logTag, "Error accessing word-level details: ${e.message}", e)
//                            }

                            // PronunciationAssessmentResult에는 getPhonemes() 메서드가 없는 것 같습니다.
                            // 원본 JSON 응답에서 음소 정보를 추출하는 방식으로 대체합니다.
//                            try {
//                                if (originalJson != null && originalJson.isNotEmpty()) {
//                                    val jsonReader = Json.createReader(StringReader(originalJson))
//                                    val originalJsonObject = jsonReader.readObject()
//                                    jsonReader.close()
//
//                                    // NBest 배열에서 첫 번째 결과의 Words 배열 검색
//                                    val nBestArray = originalJsonObject.getJsonArray("NBest")
//                                    if (nBestArray != null && nBestArray.size > 0) {
//                                        val firstResult = nBestArray.getJsonObject(0)
//                                        val wordsArray = firstResult.getJsonArray("Words")
//
//                                        if (wordsArray != null) {
//                                            val allPhonemesBuilder = javax.json.Json.createArrayBuilder()
//
//                                            // 각 단어에서 음소 정보 추출
//                                            for (i in 0 until wordsArray.size) {
//                                                val wordObj = wordsArray.getJsonObject(i)
//                                                val phonemesArray = wordObj.getJsonArray("Phonemes")
//
//                                                if (phonemesArray != null) {
//                                                    for (j in 0 until phonemesArray.size) {
//                                                        val phonemeObj = phonemesArray.getJsonObject(j)
//                                                        val phonemeBuilder = javax.json.Json.createObjectBuilder()
//
//                                                        // 음소 텍스트 추출
//                                                        if (phonemeObj.containsKey("Phoneme")) {
//                                                            phonemeBuilder.add("Phoneme", phonemeObj.getString("Phoneme"))
//                                                        }
//
//                                                        // 정확도 점수 추출
//                                                        if (phonemeObj.containsKey("PronunciationAssessment") &&
//                                                            phonemeObj.getJsonObject("PronunciationAssessment").containsKey("AccuracyScore")) {
//                                                            phonemeBuilder.add("AccuracyScore",
//                                                                phonemeObj.getJsonObject("PronunciationAssessment").getJsonNumber("AccuracyScore").doubleValue())
//                                                        }
//
//                                                        // 오프셋 및 지속 시간 추가 (있는 경우)
//                                                        if (phonemeObj.containsKey("Offset")) {
//                                                            phonemeBuilder.add("Offset", phonemeObj.getJsonNumber("Offset").longValue())
//                                                        }
//
//                                                        if (phonemeObj.containsKey("Duration")) {
//                                                            phonemeBuilder.add("Duration", phonemeObj.getJsonNumber("Duration").longValue())
//                                                        }
//
//                                                        allPhonemesBuilder.add(phonemeBuilder)
//                                                    }
//                                                }
//                                            }
//
//                                            jsonObjectBuilder.add("Phonemes", allPhonemesBuilder)
//                                        }
//                                    }
//                                }
//                            } catch (e: Exception) {
//                                Log.e(logTag, "Error extracting phoneme details from original JSON: ${e.message}", e)
//                            }

                            // Convert the original JSON to include it in our response if possible
//                            if (originalJson != null && originalJson.isNotEmpty()) {
//                                try {
//                                    val jsonReader = Json.createReader(StringReader(originalJson))
//                                    val originalJsonObject = jsonReader.readObject()
//                                    jsonReader.close()
//
//                                    // Extract NBest results if available
//                                    val nBestArray = originalJsonObject.getJsonArray("NBest")
//                                    if (nBestArray != null && nBestArray.size > 0) {
//                                        jsonObjectBuilder.add("NBest", nBestArray)
//                                    }
//                                } catch (e: Exception) {
//                                    Log.e(logTag, "Error parsing original JSON: ${e.message}", e)
//                                    jsonObjectBuilder.add("OriginalResponseText", originalJson)
//                                }
//                            }
                            jsonObjectBuilder.add("OriginalResponseText", originalJson)

                            val assessmentJson = jsonObjectBuilder.build().toString()

                            invokeMethod("speech.onFinalResponse", s)
                            invokeMethod("speech.onAssessmentResult", assessmentJson)
                        } catch (e: Exception) {
                            Log.e(logTag, "Error processing assessment results: ${e.message}", e)
                            // Fallback to original JSON if there's an error
                            val fallbackJsonBuilder = javax.json.Json.createObjectBuilder()
                            fallbackJsonBuilder.add("OriginalResponseText", originalJson ?: "")
                            invokeMethod("speech.onFinalResponse", s)
                            invokeMethod("speech.onAssessmentResult", fallbackJsonBuilder.build().toString())
                        }
                    } else {
                        invokeMethod("speech.onFinalResponse", "")
                        invokeMethod("speech.onAssessmentResult", "")
                    }
                }
                reco.close()
            }

        } catch (exec: Exception) {
            Log.e(logTag, "ERROR: ${exec.message}", exec)
            invokeMethod("speech.onException", "Exception: " + exec.message)
        }
    }

    private fun micStreamContinuously(
        speechSubscriptionKey: String, serviceRegion: String, lang: String
    ) {
        val logTag: String = "micStreamContinuous"

        Log.i(logTag, "Continuous recognition started: $continuousListeningStarted")

        if (continuousListeningStarted) {
            val _task1 = reco.stopContinuousRecognitionAsync()

            setOnTaskCompletedListener(_task1) { result ->
                Log.i(logTag, "Continuous recognition stopped.")
                continuousListeningStarted = false
                invokeMethod("speech.onRecognitionStopped", null)
                reco.close()
            }
            return
        }

        try {
            val audioConfig: AudioConfig = AudioConfig.fromDefaultMicrophoneInput()

            val config: SpeechConfig =
                SpeechConfig.fromSubscription(speechSubscriptionKey, serviceRegion)

            config.speechRecognitionLanguage = lang

            reco = SpeechRecognizer(config, audioConfig)

            reco.recognizing.addEventListener { _, speechRecognitionResultEventArgs ->
                val s = speechRecognitionResultEventArgs.result.text
                Log.i(logTag, "Intermediate result received: $s")
                invokeMethod("speech.onSpeech", s)
            }

            reco.recognized.addEventListener { _, speechRecognitionResultEventArgs ->
                val s = speechRecognitionResultEventArgs.result.text
                Log.i(logTag, "Final result received: $s")
                invokeMethod("speech.onFinalResponse", s)
            }

            val _task2 = reco.startContinuousRecognitionAsync()

            setOnTaskCompletedListener(_task2) {
                continuousListeningStarted = true
                invokeMethod("speech.onRecognitionStarted", null)
            }
        } catch (exec: Exception) {
            assert(false)
            invokeMethod("speech.onException", "Exception: " + exec.message)
        }
    }

    private fun stopContinuousMicStream(flutterResult: Result) {
        val logTag: String = "stopContinuousMicStream"

        Log.i(logTag, "Continuous recognition started: $continuousListeningStarted")

        if (continuousListeningStarted) {
            val _task1 = reco.stopContinuousRecognitionAsync()

            setOnTaskCompletedListener(_task1) { result ->
                Log.i(logTag, "Continuous recognition stopped.")
                continuousListeningStarted = false
                invokeMethod("speech.onRecognitionStopped", null)
                reco.close()
                flutterResult.success(true)
            }
            return
        }
    }

    private fun micStreamContinuouslyWithAssessment(
        referenceText: String,
        phonemeAlphabet: String,
        granularity: PronunciationAssessmentGranularity,
        enableMiscue: Boolean,
        speechSubscriptionKey: String,
        serviceRegion: String,
        lang: String,
        nBestPhonemeCount: Int?,
    ) {
        val logTag: String = "micStreamContinuousWithAssessment"

        Log.i(logTag, "Continuous recognition started: $continuousListeningStarted")

        if (continuousListeningStarted) {
            val endingTask = reco.stopContinuousRecognitionAsync()

            setOnTaskCompletedListener(endingTask) { result ->
                Log.i(logTag, "Continuous recognition stopped.")
                continuousListeningStarted = false
                invokeMethod("speech.onRecognitionStopped", null)
                reco.close()
            }
            return
        }

        try {
            val audioConfig: AudioConfig = AudioConfig.fromDefaultMicrophoneInput()

            val config: SpeechConfig =
                SpeechConfig.fromSubscription(speechSubscriptionKey, serviceRegion)

            config.speechRecognitionLanguage = lang

            var pronunciationAssessmentConfig: PronunciationAssessmentConfig =
                PronunciationAssessmentConfig(
                    referenceText,
                    PronunciationAssessmentGradingSystem.HundredMark,
                    granularity,
                    enableMiscue
                )
            pronunciationAssessmentConfig.setPhonemeAlphabet(phonemeAlphabet)

            if (nBestPhonemeCount != null) {
                pronunciationAssessmentConfig.setNBestPhonemeCount(nBestPhonemeCount)
            }

            Log.i(logTag, pronunciationAssessmentConfig.toJson())

            reco = SpeechRecognizer(config, audioConfig)

            pronunciationAssessmentConfig.applyTo(reco)

            reco.recognizing.addEventListener { _, speechRecognitionResultEventArgs ->
                val s = speechRecognitionResultEventArgs.result.text
                Log.i(logTag, "Intermediate result received: $s")
                invokeMethod("speech.onSpeech", s)
            }

            reco.recognized.addEventListener { _, speechRecognitionResultEventArgs ->
                val result = speechRecognitionResultEventArgs.result;
                val s = result.text
                val pronunciationAssessmentResultJson =
                    result.properties.getProperty(PropertyId.SpeechServiceResponse_JsonResult)
                Log.i(logTag, "Final result received: $s")
                Log.i(
                    logTag, "pronunciationAssessmentResultJson: $pronunciationAssessmentResultJson"
                )
                invokeMethod("speech.onFinalResponse", s)
                invokeMethod("speech.onAssessmentResult", pronunciationAssessmentResultJson)
            }

            val startingTask = reco.startContinuousRecognitionAsync()

            setOnTaskCompletedListener(startingTask) {
                continuousListeningStarted = true
                invokeMethod("speech.onRecognitionStarted", null)
            }
        } catch (exec: Exception) {
            assert(false)
            invokeMethod("speech.onException", "Exception: " + exec.message)
        }
    }

    private val s_executorService: ExecutorService = Executors.newCachedThreadPool()


    private fun <T> setOnTaskCompletedListener(task: Future<T>, listener: (T) -> Unit) {
        s_executorService.submit {
            val result = task.get()
            listener(result)
        }
    }

    private fun invokeMethod(method: String, arguments: Any?) {
        handler.post {
            azureChannel.invokeMethod(method, arguments)
        }
    }

    class Word(var word: String, var errorType: String) {
        var accuracyScore: Double = 0.0
        var duration: Double = 0.0

        constructor(word: String, errorType: String, accuracyScore: Double) : this(
            word,
            errorType
        ) {
            this.accuracyScore = accuracyScore
        }

        constructor(
            word: String,
            errorType: String,
            accuracyScore: Double,
            duration: Double
        ) : this(word, errorType, accuracyScore) {
            this.duration = duration
        }
    }
}
