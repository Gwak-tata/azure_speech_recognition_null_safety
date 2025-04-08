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
                            // Create a JSON object builder for scores
                            val jsonObjectBuilder = javax.json.Json.createObjectBuilder()

                            try {
                                // Use the PronunciationAssessmentResult class to get assessment results
                                val pronResult = PronunciationAssessmentResult.fromResult(result)

                                // Check if pronResult is not null before accessing properties
                                if (pronResult != null) {
                                    // Extract all scores directly from the PronunciationAssessmentResult
                                    // Use safe calls to avoid NPE if any score method returns null
                                    val accuracyScore = pronResult.getAccuracyScore() ?: 0.0
                                    val fluencyScore = pronResult.getFluencyScore() ?: 0.0
                                    val completenessScore = pronResult.getCompletenessScore() ?: 0.0
                                    val prosodyScore = pronResult.getProsodyScore() ?: 0.0
                                    val pronunciationScore = pronResult.getPronunciationScore() ?: 0.0

                                    // Add scores to JSON object
                                    jsonObjectBuilder.add("AccuracyScore", accuracyScore)
                                    jsonObjectBuilder.add("ProsodyScore", prosodyScore)
                                    jsonObjectBuilder.add("FluencyScore", fluencyScore)
                                    jsonObjectBuilder.add("CompletenessScore", completenessScore)
                                    jsonObjectBuilder.add("PronunciationScore", pronunciationScore)

                                    // Log scores
                                    val logMessage = "Scores - Accuracy: $accuracyScore, Prosody: $prosodyScore, " +
                                            "Fluency: $fluencyScore, Completeness: $completenessScore, " +
                                            "Pronunciation: $pronunciationScore"

                                    // Get content assessment scores if topic was provided
                                    if (topic != null) {
                                        try {
                                            // Try to get the content assessment result with null safety
                                            val getContentMethod = pronResult.javaClass.getMethod("getContentAssessmentResult")
                                            val contentResult = getContentMethod.invoke(pronResult)

                                            if (contentResult != null) {
                                                val contentClass = contentResult.javaClass
                                                var grammarScore = 0.0
                                                var vocabScore = 0.0
                                                var topicScore = 0.0
                                                var contentLogMessage = ""

                                                // Get grammar score
                                                try {
                                                    val getGrammarMethod = contentClass.getMethod("getGrammarScore")
                                                    grammarScore = (getGrammarMethod.invoke(contentResult) as? Double) ?: 0.0
                                                    jsonObjectBuilder.add("GrammarScore", grammarScore)
                                                    contentLogMessage += ", Grammar: $grammarScore"
                                                } catch (e: Exception) {
                                                    Log.e(logTag, "Error getting grammar score: ${e.message}", e)
                                                }

                                                // Get vocabulary score
                                                try {
                                                    val getVocabMethod = contentClass.getMethod("getVocabularyScore")
                                                    vocabScore = (getVocabMethod.invoke(contentResult) as? Double) ?: 0.0
                                                    jsonObjectBuilder.add("VocabularyScore", vocabScore)
                                                    contentLogMessage += ", Vocabulary: $vocabScore"
                                                } catch (e: Exception) {
                                                    Log.e(logTag, "Error getting vocabulary score: ${e.message}", e)
                                                }

                                                // Get topic score
                                                try {
                                                    val getTopicMethod = contentClass.getMethod("getTopicScore")
                                                    topicScore = (getTopicMethod.invoke(contentResult) as? Double) ?: 0.0
                                                    jsonObjectBuilder.add("TopicScore", topicScore)
                                                    contentLogMessage += ", Topic: $topicScore"
                                                } catch (e: Exception) {
                                                    Log.e(logTag, "Error getting topic score: ${e.message}", e)
                                                }

                                                // Log content assessment scores
                                                Log.i(logTag, logMessage + contentLogMessage)
                                            } else {
                                                Log.i(logTag, logMessage)
                                            }
                                        } catch (e: Exception) {
                                            Log.e(logTag, "Error getting content assessment result: ${e.message}", e)
                                            Log.i(logTag, logMessage)
                                        }
                                    } else {
                                        Log.i(logTag, logMessage)
                                    }
                                } else {
                                    Log.e(logTag, "PronunciationAssessmentResult is null")
                                }
                            } catch (e: Exception) {
                                Log.e(logTag, "Error getting pronunciation assessment result: ${e.message}", e)
                            }

                            // Always add original JSON response
                            jsonObjectBuilder.add("OriginalResponseText", originalJson ?: "")
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
