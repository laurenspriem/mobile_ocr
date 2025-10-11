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

data class CharacterBox(
    val text: String,
    val confidence: Float,
    val points: List<PointF>
)

data class OcrResult(
    val boxes: List<TextBox>,
    val texts: List<String>,
    val scores: List<Float>,
    val characters: List<List<CharacterBox>>
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
        // Step 1: Text Detection
        val detectionResult = detectText(bitmap)

        if (detectionResult.isEmpty()) {
            return OcrResult(emptyList(), emptyList(), emptyList(), emptyList())
        }

        // Step 2: Crop text regions
        val croppedImages = detectionResult.mapIndexed { index, box ->
            val cropped = cropTextRegion(bitmap, box)
            saveDebugBitmap(cropped, "crop", index, "raw")
            cropped
        }.toMutableList()

        val classificationMask = BooleanArray(croppedImages.size)
        val rotationStates = BooleanArray(croppedImages.size)

        if (useAngleClassification) {
            val aspectCandidates = croppedImages.mapIndexedNotNull { index, image ->
                val aspectRatio = image.width.toFloat() / image.height
                if (aspectRatio < ANGLE_ASPECT_RATIO_THRESHOLD) index else null
            }
            classifyAndRotateIndices(
                croppedImages,
                aspectCandidates,
                classificationMask,
                rotationStates,
                "angle_aspect"
            )
        }

        // Step 3: Text recognition
        val recognitionResults = recognizeText(croppedImages).toMutableList()

        if (useAngleClassification && recognitionResults.isNotEmpty()) {
            val lowConfidenceIndices = recognitionResults.mapIndexedNotNull { index, result ->
                if (!classificationMask[index] && result.confidence < LOW_CONFIDENCE_THRESHOLD) index else null
            }

            if (lowConfidenceIndices.isNotEmpty()) {
                classifyAndRotateIndices(
                    croppedImages,
                    lowConfidenceIndices,
                    classificationMask,
                    rotationStates,
                    "angle_confidence"
                )
                val refreshed = recognizeText(lowConfidenceIndices.map { croppedImages[it] })
                lowConfidenceIndices.forEachIndexed { refreshedIndex, originalIndex ->
                    val current = recognitionResults[originalIndex]
                    val updated = refreshed[refreshedIndex]
                    recognitionResults[originalIndex] =
                        if (updated.confidence > current.confidence) updated else current
                }
            }
        }

        if (debugOptions.logRecognition) {
            logDebug("Detected ${recognitionResults.size} regions")
            recognitionResults.forEachIndexed { index, result ->
                logDebug("[$index] score=${"%.3f".format(result.confidence)} text=${result.text}")
            }
        }

        val characterBoxesPerDetection = recognitionResults.mapIndexed { index, result ->
            buildCharacterBoxes(
                detectionResult[index],
                result.characterSpans,
                rotationStates[index]
            )
        }

        // Step 4: Filter by confidence score
        val minThreshold = if (includeAllConfidenceScores) FALLBACK_MIN_RECOGNITION_SCORE else MIN_RECOGNITION_SCORE
        val filteredResults = mutableListOf<TextBox>()
        val filteredTexts = mutableListOf<String>()
        val filteredScores = mutableListOf<Float>()
        val filteredCharacters = mutableListOf<List<CharacterBox>>()

        for (i in recognitionResults.indices) {
            val recognition = recognitionResults[i]
            if (recognition.confidence >= minThreshold) {
                filteredResults.add(detectionResult[i])
                filteredTexts.add(recognition.text)
                filteredScores.add(recognition.confidence)
                filteredCharacters.add(characterBoxesPerDetection[i])
            }
        }

        return OcrResult(filteredResults, filteredTexts, filteredScores, filteredCharacters)
    }

    private fun detectText(bitmap: Bitmap): List<TextBox> {
        val processor = TextDetector(detectionSession, ortEnv)
        return processor.detect(bitmap)
    }

    fun hasHighConfidenceText(
        bitmap: Bitmap,
        minimumDetectionConfidence: Float = 0.9f
    ): Boolean {
        val processor = TextDetector(detectionSession, ortEnv)
        return processor.hasHighConfidenceDetection(bitmap, minimumDetectionConfidence)
    }

    private fun cropTextRegion(bitmap: Bitmap, box: TextBox): Bitmap {
        val orderedPoints = ImageUtils.orderPointsClockwise(box.points)
        return ImageUtils.cropTextRegion(bitmap, orderedPoints)
    }

    private fun buildCharacterBoxes(
        textBox: TextBox,
        spans: List<CharacterSpan>,
        rotated: Boolean
    ): List<CharacterBox> {
        if (spans.isEmpty()) {
            return emptyList()
        }

        val ordered = ImageUtils.orderPointsClockwise(textBox.points)
        if (ordered.size != 4) {
            return emptyList()
        }

        val topLeft = ordered[0]
        val topRight = ordered[1]
        val bottomRight = ordered[2]
        val bottomLeft = ordered[3]

        val epsilon = 1e-4f

        return spans.mapNotNull { span ->
            var start = span.startRatio
            var end = span.endRatio

            if (rotated) {
                val reversedStart = 1f - end
                val reversedEnd = 1f - start
                start = reversedStart.coerceIn(0f, 1f)
                end = reversedEnd.coerceIn(start + epsilon, 1f)
            }

            val clampedStart = start.coerceIn(0f, 1f)
            val clampedEnd = end.coerceIn(clampedStart + epsilon, 1f)
            if (clampedEnd - clampedStart <= epsilon) {
                return@mapNotNull null
            }

            val topStart = interpolate(topLeft, topRight, clampedStart)
            val topEnd = interpolate(topLeft, topRight, clampedEnd)
            val bottomStart = interpolate(bottomLeft, bottomRight, clampedStart)
            val bottomEnd = interpolate(bottomLeft, bottomRight, clampedEnd)

            CharacterBox(
                text = span.text,
                confidence = span.confidence,
                points = listOf(topStart, topEnd, bottomEnd, bottomStart)
            )
        }
    }

    private fun interpolate(start: PointF, end: PointF, ratio: Float): PointF {
        val clamped = ratio.coerceIn(0f, 1f)
        return PointF(
            start.x + (end.x - start.x) * clamped,
            start.y + (end.y - start.y) * clamped
        )
    }

    private fun classifyAndRotateIndices(
        images: MutableList<Bitmap>,
        indices: List<Int>,
        classificationMask: BooleanArray,
        rotationStates: BooleanArray,
        stageLabel: String
    ) {
        if (!useAngleClassification || indices.isEmpty()) {
            return
        }

        val session = classificationSession
            ?: throw IllegalStateException("Angle classification requested but model not loaded")

        val classifier = TextClassifier(session, ortEnv)
        val subset = indices.map { images[it] }
        val outputs = classifier.classifyAndRotate(subset)

        indices.forEachIndexed { idx, imageIndex ->
            classificationMask[imageIndex] = true
            val output = outputs[idx]
            if (output.rotated) {
                rotationStates[imageIndex] = !rotationStates[imageIndex]
            }
            images[imageIndex] = output.bitmap
            saveDebugBitmap(output.bitmap, "crop", imageIndex, stageLabel)
        }
    }

    private fun recognizeText(images: List<Bitmap>): List<RecognitionResult> {
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
