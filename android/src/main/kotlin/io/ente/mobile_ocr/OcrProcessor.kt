package io.ente.mobile_ocr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.PointF
import android.graphics.RectF
import android.util.Log
import ai.onnxruntime.*
import java.io.File
import java.io.FileOutputStream
import java.util.Locale

data class OcrResult(
    val boxes: List<TextBox>,
    val texts: List<String>,
    val scores: List<Float>
)

data class TextBox(
    val points: List<PointF>
) {
    fun boundingRect(): RectF {
        if (points.isEmpty()) {
            return RectF()
        }

        var minX = points[0].x
        var maxX = points[0].x
        var minY = points[0].y
        var maxY = points[0].y

        for (point in points) {
            if (point.x < minX) minX = point.x
            if (point.x > maxX) maxX = point.x
            if (point.y < minY) minY = point.y
            if (point.y > maxY) maxY = point.y
        }

        return RectF(minX, minY, maxX, maxY)
    }
}

data class DebugOptions(
    val saveCrops: Boolean = false,
    val logRecognition: Boolean = false,
    val outputDirectoryName: String = "onnx_ocr_debug"
)

class OcrProcessor(
    private val context: Context,
    private val modelFiles: ModelFiles,
    private val useAngleClassification: Boolean = true,
    private val debugOptions: DebugOptions = DebugOptions()
) {
    companion object {
        private const val MIN_RECOGNITION_SCORE = 0.8f
        private const val FALLBACK_MIN_RECOGNITION_SCORE = 0.5f
        private const val ANGLE_ASPECT_RATIO_THRESHOLD = 0.5f
        private const val LOW_CONFIDENCE_THRESHOLD = 0.65f
        private const val DEBUG_TAG = "OnnxOcrDebug"
    }

    private val ortEnv = OrtEnvironment.getEnvironment()
    private val sessionOptions = OrtSession.SessionOptions().apply {
        setOptimizationLevel(OrtSession.SessionOptions.OptLevel.BASIC_OPT)
    }

    private lateinit var detectionSession: OrtSession
    private lateinit var recognitionSession: OrtSession
    private var classificationSession: OrtSession? = null

    private lateinit var characterDict: List<String>

    init {
        loadSessions()
        loadCharacterDict()
    }

    private fun loadSessions() {
        detectionSession = ortEnv.createSession(modelFiles.detectionModel.absolutePath, sessionOptions)
        recognitionSession = ortEnv.createSession(modelFiles.recognitionModel.absolutePath, sessionOptions)

        if (useAngleClassification) {
            classificationSession = ortEnv.createSession(modelFiles.classificationModel.absolutePath, sessionOptions)
        }
    }

    private fun loadCharacterDict() {
        modelFiles.dictionaryFile.inputStream().use { stream ->
            val characters = stream.bufferedReader().readLines().toMutableList()
            characters.add(" ")
            characterDict = listOf("blank") + characters
        }
    }

    fun processImage(bitmap: Bitmap, includeAllConfidenceScores: Boolean = false): OcrResult {
        return OcrPerformanceLogger.trace("OcrProcessor#processImage") {
            val detectionResult = OcrPerformanceLogger.trace("OcrProcessor#detectText") {
                detectText(bitmap)
            }

            if (detectionResult.isEmpty()) {
                OcrPerformanceLogger.log("OcrProcessor: no detections found")
                return@trace OcrResult(emptyList(), emptyList(), emptyList())
            }

            OcrPerformanceLogger.log("OcrProcessor: detected ${detectionResult.size} regions")

            val croppedImages = OcrPerformanceLogger.trace("OcrProcessor#cropTextRegions") {
                detectionResult.mapIndexed { index, box ->
                    val cropped = cropTextRegion(bitmap, box)
                    saveDebugBitmap(cropped, "crop", index, "raw")
                    cropped
                }.toMutableList()
            }

            val classificationMask = BooleanArray(croppedImages.size)

            if (useAngleClassification) {
                val aspectCandidates = OcrPerformanceLogger.trace("OcrProcessor#selectAspectCandidates") {
                    croppedImages.mapIndexedNotNull { index, image ->
                        val aspectRatio = image.width.toFloat() / image.height
                        if (aspectRatio < ANGLE_ASPECT_RATIO_THRESHOLD) index else null
                    }
                }
                if (aspectCandidates.isNotEmpty()) {
                    classifyAndRotateIndices(croppedImages, aspectCandidates, classificationMask, "angle_aspect")
                }
            }

            val recognitionResults = OcrPerformanceLogger.trace("OcrProcessor#recognizeText") {
                recognizeText(croppedImages).toMutableList()
            }

            if (useAngleClassification && recognitionResults.isNotEmpty()) {
                val lowConfidenceIndices = OcrPerformanceLogger.trace("OcrProcessor#selectLowConfidence") {
                    recognitionResults.mapIndexedNotNull { index, result ->
                        if (!classificationMask[index] && result.second < LOW_CONFIDENCE_THRESHOLD) index else null
                    }
                }

                if (lowConfidenceIndices.isNotEmpty()) {
                    classifyAndRotateIndices(croppedImages, lowConfidenceIndices, classificationMask, "angle_confidence")
                    val refreshed = OcrPerformanceLogger.trace("OcrProcessor#reRecognizeLowConfidence") {
                        recognizeText(lowConfidenceIndices.map { croppedImages[it] })
                    }
                    lowConfidenceIndices.forEachIndexed { refreshedIndex, originalIndex ->
                        val current = recognitionResults[originalIndex]
                        val updated = refreshed[refreshedIndex]
                        recognitionResults[originalIndex] = if (updated.second > current.second) updated else current
                    }
                }
            }

            if (debugOptions.logRecognition) {
                logDebug("Detected ${recognitionResults.size} regions")
                recognitionResults.forEachIndexed { index, (text, score) ->
                    logDebug("[$index] score=${"%.3f".format(score)} text=$text")
                }
            }

            val minThreshold = if (includeAllConfidenceScores) FALLBACK_MIN_RECOGNITION_SCORE else MIN_RECOGNITION_SCORE
            val filteredResults = mutableListOf<TextBox>()
            val filteredTexts = mutableListOf<String>()
            val filteredScores = mutableListOf<Float>()

            for (i in recognitionResults.indices) {
                val (text, score) = recognitionResults[i]
                if (score >= minThreshold) {
                    filteredResults.add(detectionResult[i])
                    filteredTexts.add(text)
                    filteredScores.add(score)
                }
            }

            OcrPerformanceLogger.log("OcrProcessor: returning ${filteredResults.size} results after filtering")

            OcrResult(filteredResults, filteredTexts, filteredScores)
        }
    }

    private fun detectText(bitmap: Bitmap): List<TextBox> {
        val processor = TextDetector(detectionSession, ortEnv)
        return processor.detect(bitmap)
    }

    private fun cropTextRegion(bitmap: Bitmap, box: TextBox): Bitmap {
        val orderedPoints = ImageUtils.orderPointsClockwise(box.points)
        return ImageUtils.cropTextRegion(bitmap, orderedPoints)
    }

    private fun classifyAndRotateIndices(
        images: MutableList<Bitmap>,
        indices: List<Int>,
        classificationMask: BooleanArray,
        stageLabel: String
    ) {
        if (!useAngleClassification || indices.isEmpty()) {
            return
        }

        val session = classificationSession
            ?: throw IllegalStateException("Angle classification requested but model not loaded")

        OcrPerformanceLogger.trace("OcrProcessor#classifyAndRotate(stage=$stageLabel)") {
            val classifier = TextClassifier(session, ortEnv)
            val subset = indices.map { images[it] }
            val rotated = classifier.classifyAndRotate(subset)

            indices.forEachIndexed { idx, imageIndex ->
                classificationMask[imageIndex] = true
                images[imageIndex] = rotated[idx]
                saveDebugBitmap(rotated[idx], "crop", imageIndex, stageLabel)
            }
        }
    }

    private fun recognizeText(images: List<Bitmap>): List<Pair<String, Float>> {
        val recognizer = TextRecognizer(recognitionSession, ortEnv, characterDict)
        return recognizer.recognize(images)
    }

    private fun saveDebugBitmap(bitmap: Bitmap, prefix: String, index: Int, stage: String) {
        if (!debugOptions.saveCrops) {
            return
        }

        runCatching {
            val directory = File(context.cacheDir, debugOptions.outputDirectoryName)
            if (!directory.exists()) {
                directory.mkdirs()
            }

            val fileName = String.format(Locale.US, "%s_%03d_%s.png", prefix, index, stage)
            val outputFile = File(directory, fileName)
            FileOutputStream(outputFile).use { stream ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            }
        }.onFailure { error ->
            Log.w(DEBUG_TAG, "Failed to save debug bitmap: ${error.message}")
        }
    }

    private fun logDebug(message: String) {
        if (debugOptions.logRecognition) {
            Log.d(DEBUG_TAG, message)
        }
    }

    fun close() {
        detectionSession.close()
        recognitionSession.close()
        classificationSession?.close()
    }
}
