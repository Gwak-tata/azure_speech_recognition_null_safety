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
                    enableMiscue ?: false
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

            // Lists to store assessment data
            val recognizedWords = mutableListOf<String>()
            val pronWords = mutableListOf<Word>()
            val finalWords = mutableListOf<Word>()
            val fluencyScores = mutableListOf<Double>()
            val prosodyScores = mutableListOf<Double>()
            val durations = mutableListOf<Long>()

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
                val pronunciationAssessmentResultJson =
                    result.properties.getProperty(PropertyId.SpeechServiceResponse_JsonResult)
                Log.i(logTag, "Final result: $s\nReason: ${result.reason}")
                Log.i(
                    logTag,
                    "pronunciationAssessmentResultJson: $pronunciationAssessmentResultJson"
                )

                if (task_global === task) {
                    if (result.reason == ResultReason.RecognizedSpeech) {
                        try {
                            // Extract scores from the pronunciation assessment result
                            val pronResult = PronunciationAssessmentResult.fromResult(result)

                            // Store initial scores
                            fluencyScores.add(pronResult.getFluencyScore())
                            prosodyScores.add(pronResult.getProsodyScore())

                            // Parse the JSON response to extract word-level details
                            val jsonReader =
                                Json.createReader(StringReader(pronunciationAssessmentResultJson))
                            val jsonObject = jsonReader.readObject()
                            jsonReader.close()

                            // Process NBest results to get word-level assessments
                            val nBestArray = jsonObject.getJsonArray("NBest")
                            for (i in 0 until nBestArray.size()) {
                                val nBestItem = nBestArray.getJsonObject(i)

                                val wordsArray = nBestItem.getJsonArray("Words")
                                var durationSum: Long = 0

                                for (j in 0 until wordsArray.size()) {
                                    val wordItem = wordsArray.getJsonObject(j)
                                    recognizedWords.add(wordItem.getString("Word"))
                                    durationSum += wordItem.getJsonNumber("Duration").longValue()

                                    val pronAssessment =
                                        wordItem.getJsonObject("PronunciationAssessment")
                                    pronWords.add(
                                        Word(
                                            wordItem.getString("Word"),
                                            pronAssessment.getString("ErrorType"),
                                            pronAssessment.getJsonNumber("AccuracyScore")
                                                .doubleValue()
                                        )
                                    )
                                }
                                durations.add(durationSum)
                            }

                            // Process miscue detection if enabled
                            // Split reference text into words and clean up punctuation
                            val referenceWords =
                                referenceText.toLowerCase().split(" ").map { word ->
                                    word.replace(Regex("^\\p{Punct}+|\\p{Punct}+$"), "")
                                }.toTypedArray()

                            if (enableMiscue == true) {
                                // Use java-diff-utils library (needs to be added to dependencies)
                                try {
                                    val diff = DiffUtils.diff(
                                        referenceWords.toList(),
                                        recognizedWords,
                                        true
                                    )

                                    var currentIdx = 0
                                    for (d in diff.deltas) {
                                        when (d.type) {
                                            DeltaType.EQUAL -> {
                                                for (i in currentIdx until currentIdx + d.source.size) {
                                                    finalWords.add(pronWords[i])
                                                }
                                                currentIdx += d.target.size
                                            }

                                            DeltaType.DELETE, DeltaType.CHANGE -> {
                                                for (w in d.source.lines) {
                                                    finalWords.add(Word(w, "Omission"))
                                                }
                                            }

                                            DeltaType.INSERT, DeltaType.CHANGE -> {
                                                for (i in currentIdx until currentIdx + d.target.size) {
                                                    val w = pronWords[i]
                                                    w.errorType = "Insertion"
                                                    finalWords.add(w)
                                                }
                                                currentIdx += d.target.size
                                            }
                                        }
                                    }
                                } catch (e: Exception) {
                                    Log.e(logTag, "Error in diff processing: ${e.message}")
                                    // Fallback in case diff utils fail
                                    finalWords.addAll(pronWords)
                                }
                            } else {
                                finalWords.addAll(pronWords)
                            }

                            // Calculate overall scores
                            // 1. Calculate accuracy score
                            var totalAccuracyScore = 0.0
                            var accuracyCount = 0
                            var validCount = 0

                            for (word in finalWords) {
                                if (word.errorType != "Insertion") {
                                    totalAccuracyScore += word.accuracyScore
                                    accuracyCount++
                                }

                                if (word.errorType == "None") {
                                    validCount++
                                }
                            }

                            val accuracyScore =
                                if (accuracyCount > 0) totalAccuracyScore / accuracyCount else 0.0

                            // 2. Re-calculate fluency score
                            var fluencyScoreSum = 0.0
                            var durationSum: Long = 0

                            for (i in fluencyScores.indices) {
                                fluencyScoreSum += fluencyScores[i] * durations[i]
                                durationSum += durations[i]
                            }

                            val fluencyScore =
                                if (durationSum > 0) fluencyScoreSum / durationSum else pronResult.getFluencyScore()

                            // 3. Re-calculate prosody score
                            val prosodyScore = if (prosodyScores.isNotEmpty())
                                prosodyScores.sum() / prosodyScores.size
                            else
                                pronResult.getProsodyScore()

                            // 4. Calculate completeness score
                            val completenessScore = if (referenceWords.isNotEmpty())
                                (validCount.toDouble() / referenceWords.size * 100).coerceAtMost(
                                    100.0
                                )
                            else
                                pronResult.getCompletenessScore()

                            // 5. Calculate pronunciation score
                            val pronScore =
                                accuracyScore * 0.4 + prosodyScore * 0.2 + fluencyScore * 0.2 + completenessScore * 0.2

                            // Log the final scores
                            Log.i(
                                logTag, String.format(
                                    "Final scores - Accuracy: %.2f, Prosody: %.2f, Fluency: %.2f, " +
                                            "Completeness: %.2f, Pronunciation: %.2f",
                                    accuracyScore,
                                    prosodyScore,
                                    fluencyScore,
                                    completenessScore,
                                    pronScore
                                )
                            )

                            // Create modified JSON with all scores
                            val modifiedJsonObjectBuilder =
                                javax.json.Json.createObjectBuilder(jsonObject)
                                    .add("AccuracyScore", accuracyScore)
                                    .add("ProsodyScore", prosodyScore)
                                    .add("FluencyScore", fluencyScore)
                                    .add("CompletenessScore", completenessScore)
                                    .add("PronunciationScore", pronScore)

                            // Add word-level assessment if available
                            if (finalWords.isNotEmpty()) {
                                val wordsArrayBuilder = javax.json.Json.createArrayBuilder()

                                for (word in finalWords) {
                                    wordsArrayBuilder.add(
                                        javax.json.Json.createObjectBuilder()
                                            .add("Word", word.word)
                                            .add("ErrorType", word.errorType)
                                            .add("AccuracyScore", word.accuracyScore)
                                    )
                                }

                                modifiedJsonObjectBuilder.add("Words", wordsArrayBuilder)
                            }

                            val modifiedJsonString = modifiedJsonObjectBuilder.build().toString()

                            invokeMethod("speech.onFinalResponse", s)
                            invokeMethod("speech.onAssessmentResult", modifiedJsonString)
                        } catch (e: Exception) {
                            Log.e(logTag, "Error processing assessment results: ${e.message}", e)
                            invokeMethod("speech.onFinalResponse", s)
                            invokeMethod(
                                "speech.onAssessmentResult",
                                pronunciationAssessmentResultJson
                            )
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
