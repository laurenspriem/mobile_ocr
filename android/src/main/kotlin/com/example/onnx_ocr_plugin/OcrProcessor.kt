package com.example.onnx_ocr_plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.PointF
import ai.onnxruntime.*
import java.io.InputStream
import java.nio.FloatBuffer

data class OcrResult(
    val boxes: List<TextBox>,
    val texts: List<String>,
    val scores: List<Float>
)

data class TextBox(
    val points: List<PointF>
)

class OcrProcessor(private val context: Context) {
    private val ortEnv = OrtEnvironment.getEnvironment()
    private val sessionOptions = OrtSession.SessionOptions().apply {
        setOptimizationLevel(OrtSession.SessionOptions.OptLevel.BASIC_OPT)
    }

    private lateinit var detectionSession: OrtSession
    private lateinit var recognitionSession: OrtSession
    private lateinit var classificationSession: OrtSession

    private lateinit var characterDict: List<String>

    init {
        loadModels()
        loadCharacterDict()
    }

    private fun loadModels() {
        // Load detection model
        context.assets.open("flutter_assets/packages/onnx_ocr_plugin/assets/models/det/det.onnx").use { stream ->
            val modelBytes = stream.readBytes()
            detectionSession = ortEnv.createSession(modelBytes, sessionOptions)
        }

        // Load recognition model
        context.assets.open("flutter_assets/packages/onnx_ocr_plugin/assets/models/rec/rec.onnx").use { stream ->
            val modelBytes = stream.readBytes()
            recognitionSession = ortEnv.createSession(modelBytes, sessionOptions)
        }

        // Load classification model
        context.assets.open("flutter_assets/packages/onnx_ocr_plugin/assets/models/cls/cls.onnx").use { stream ->
            val modelBytes = stream.readBytes()
            classificationSession = ortEnv.createSession(modelBytes, sessionOptions)
        }
    }

    private fun loadCharacterDict() {
        context.assets.open("flutter_assets/packages/onnx_ocr_plugin/assets/models/ppocrv5_dict.txt").use { stream ->
            val characters = stream.bufferedReader().readLines().toMutableList()
            // Add space character (matching use_space_char=True, the Python default)
            characters.add(" ")
            // Add CTC blank token at the beginning (CTCLabelDecode.add_special_char)
            characterDict = listOf("blank") + characters
        }
    }

    fun processImage(bitmap: Bitmap): OcrResult {
        // Step 1: Text Detection
        val detectionResult = detectText(bitmap)

        if (detectionResult.isEmpty()) {
            return OcrResult(emptyList(), emptyList(), emptyList())
        }

        // Step 2: Crop text regions
        val croppedImages = detectionResult.map { box ->
            cropTextRegion(bitmap, box)
        }

        // Step 3: Optional text angle classification
        val alignedImages = classifyAndRotateImages(croppedImages)

        // Step 4: Text recognition
        val recognitionResults = recognizeText(alignedImages)

        // Step 5: Filter by confidence score
        val minScore = 0.5f
        val filteredResults = mutableListOf<TextBox>()
        val filteredTexts = mutableListOf<String>()
        val filteredScores = mutableListOf<Float>()

        for (i in recognitionResults.indices) {
            if (recognitionResults[i].second >= minScore) {
                filteredResults.add(detectionResult[i])
                filteredTexts.add(recognitionResults[i].first)
                filteredScores.add(recognitionResults[i].second)
            }
        }

        return OcrResult(filteredResults, filteredTexts, filteredScores)
    }

    private fun detectText(bitmap: Bitmap): List<TextBox> {
        val processor = TextDetector(detectionSession, ortEnv)
        return processor.detect(bitmap)
    }

    private fun cropTextRegion(bitmap: Bitmap, box: TextBox): Bitmap {
        return ImageUtils.cropTextRegion(bitmap, box.points)
    }

    private fun classifyAndRotateImages(images: List<Bitmap>): List<Bitmap> {
        val classifier = TextClassifier(classificationSession, ortEnv)
        return classifier.classifyAndRotate(images)
    }

    private fun recognizeText(images: List<Bitmap>): List<Pair<String, Float>> {
        val recognizer = TextRecognizer(recognitionSession, ortEnv, characterDict)
        return recognizer.recognize(images)
    }

    fun close() {
        detectionSession.close()
        recognitionSession.close()
        classificationSession.close()
    }
}