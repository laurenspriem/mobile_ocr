package io.ente.mobile_ocr

import android.graphics.Bitmap
import ai.onnxruntime.*
import java.nio.FloatBuffer
import kotlin.math.*

data class CharacterSpan(
    val text: String,
    val confidence: Float,
    val startRatio: Float,
    val endRatio: Float
)

data class RecognitionResult(
    val text: String,
    val confidence: Float,
    val characterSpans: List<CharacterSpan>
)

class TextRecognizer(
    private val session: OrtSession,
    private val ortEnv: OrtEnvironment,
    private val characterDict: List<String>
) {
    companion object {
        private const val IMG_HEIGHT = 48
        private const val IMG_WIDTH = 320
        private const val BATCH_SIZE = 6
        private const val MIN_SPAN_RATIO = 1e-3f
    }

    fun recognize(images: List<Bitmap>): List<RecognitionResult> {
        if (images.isEmpty()) {
            return emptyList()
        }

        val widthList = images.map { it.width.toFloat() / it.height }
        val sortedIndices = widthList.indices.sortedBy { widthList[it] }
        val orderedResults = MutableList(images.size) {
            RecognitionResult("", 0f, emptyList())
        }

        for (start in sortedIndices.indices step BATCH_SIZE) {
            val end = min(start + BATCH_SIZE, sortedIndices.size)
            val batchIndices = sortedIndices.subList(start, end)
            val batchBitmaps = batchIndices.map { images[it] }
            val batchResults = processBatch(batchBitmaps)

            batchIndices.forEachIndexed { idx, originalIndex ->
                orderedResults[originalIndex] = batchResults[idx]
            }
        }

        return orderedResults
    }

    private fun processBatch(batchImages: List<Bitmap>): List<RecognitionResult> {
        if (batchImages.isEmpty()) return emptyList()

        // Calculate max width-height ratio for the batch (baseline ratio aligns with Python implementation)
        var maxWhRatio = IMG_WIDTH.toFloat() / IMG_HEIGHT
        for (image in batchImages) {
            val ratio = image.width.toFloat() / image.height
            if (ratio > maxWhRatio) {
                maxWhRatio = ratio
            }
        }

        val targetWidth = ceil(IMG_HEIGHT * maxWhRatio).toInt().coerceAtLeast(1)

        // Prepare batch input
        val batchSize = batchImages.size
        val inputArray = FloatArray(batchSize * 3 * IMG_HEIGHT * targetWidth)

        val contentWidths = IntArray(batchSize)
        for ((index, image) in batchImages.withIndex()) {
            val resizedWidth = preprocessImage(image, inputArray, index, targetWidth)
            contentWidths[index] = resizedWidth
        }

        // Create tensor
        val shape = longArrayOf(batchSize.toLong(), 3, IMG_HEIGHT.toLong(), targetWidth.toLong())
        val inputTensor = OnnxTensor.createTensor(ortEnv, FloatBuffer.wrap(inputArray), shape)

        // Run inference
        val inputs = mapOf(session.inputNames.first() to inputTensor)
        val outputs = session.run(inputs)
        val output = outputs[0] as OnnxTensor

        // Decode results
        val results = decodeOutput(output, batchSize, contentWidths, targetWidth)

        output.close()
        inputTensor.close()

        return results
    }

    private fun preprocessImage(
        bitmap: Bitmap,
        outputArray: FloatArray,
        batchIndex: Int,
        targetWidth: Int
    ): Int {
        // Calculate resize dimensions maintaining aspect ratio
        val aspectRatio = bitmap.width.toFloat() / bitmap.height
        val resizedWidth = min(
            ceil(IMG_HEIGHT * aspectRatio).toInt().coerceAtLeast(1),
            targetWidth
        )

        // Resize bitmap
        val resizedBitmap = Bitmap.createScaledBitmap(bitmap, resizedWidth, IMG_HEIGHT, true)

        // Get pixels
        val pixels = IntArray(resizedWidth * IMG_HEIGHT)
        resizedBitmap.getPixels(pixels, 0, resizedWidth, 0, 0, resizedWidth, IMG_HEIGHT)
        resizedBitmap.recycle()

        // Normalize and convert to CHW format
        val baseOffset = batchIndex * 3 * IMG_HEIGHT * targetWidth

        val channelStride = IMG_HEIGHT * targetWidth

        for (y in 0 until IMG_HEIGHT) {
            val rowOffset = y * targetWidth
            val sourceRowOffset = y * resizedWidth

            for (x in 0 until targetWidth) {
                val pixelIndex = rowOffset + x

                if (x < resizedWidth) {
                    val pixel = pixels[sourceRowOffset + x]
                    val b = (pixel and 0xFF) / 255.0f
                    val g = ((pixel shr 8) and 0xFF) / 255.0f
                    val r = ((pixel shr 16) and 0xFF) / 255.0f

                    outputArray[baseOffset + pixelIndex] = (b - 0.5f) / 0.5f
                    outputArray[baseOffset + channelStride + pixelIndex] = (g - 0.5f) / 0.5f
                    outputArray[baseOffset + 2 * channelStride + pixelIndex] = (r - 0.5f) / 0.5f
                } else {
                    outputArray[baseOffset + pixelIndex] = 0f
                    outputArray[baseOffset + channelStride + pixelIndex] = 0f
                    outputArray[baseOffset + 2 * channelStride + pixelIndex] = 0f
                }
            }
        }

        return resizedWidth
    }

    private fun decodeOutput(output: OnnxTensor, batchSize: Int, contentWidths: IntArray, targetWidth: Int): List<RecognitionResult> {
        val outputArray = output.floatBuffer.array()
        val shape = output.info.shape
        val seqLen = shape[1].toInt()
        val vocabSize = shape[2].toInt()

        val results = mutableListOf<RecognitionResult>()

        for (b in 0 until batchSize) {
            val batchOffset = b * seqLen * vocabSize

            // Get argmax and probabilities for each time step
            val charIndices = IntArray(seqLen)
            val probs = FloatArray(seqLen)

            for (t in 0 until seqLen) {
                val timeOffset = batchOffset + t * vocabSize

                var maxProb = outputArray[timeOffset]
                var maxIndex = 0

                for (c in 1 until vocabSize) {
                    val prob = outputArray[timeOffset + c]
                    if (prob > maxProb) {
                        maxProb = prob
                        maxIndex = c
                    }
                }

                charIndices[t] = maxIndex
                probs[t] = maxProb
            }

            val contentWidth = if (b < contentWidths.size && contentWidths[b] > 0) {
                contentWidths[b]
            } else {
                targetWidth
            }
            val scaleFactor = if (contentWidth >= targetWidth) 1f else targetWidth.toFloat() / contentWidth
            val recognition = ctcDecode(charIndices, probs, scaleFactor)

            results.add(recognition)
        }

        return results
    }

    private fun ctcDecode(charIndices: IntArray, probs: FloatArray, scale: Float): RecognitionResult {
        val seqLen = charIndices.size
        if (seqLen == 0) {
            return RecognitionResult("", 0f, emptyList())
        }

        val safeScale = if (scale.isFinite() && scale > 0f) scale else 1f
        val decodedChars = mutableListOf<String>()
        val decodedProbs = mutableListOf<Float>()
        val spans = mutableListOf<CharacterSpan>()

        var t = 0
        while (t < seqLen) {
            val currentIndex = charIndices[t]

            if (currentIndex == 0) {
                t++
                continue
            }

            val start = t
            var end = t + 1
            var probSum = probs[t]
            var count = 1

            while (end < seqLen && charIndices[end] == currentIndex) {
                probSum += probs[end]
                end++
                count++
            }

            if (currentIndex < characterDict.size) {
                val character = characterDict[currentIndex]
                decodedChars.add(character)

                val meanProb = probSum / count
                decodedProbs.add(meanProb)

                val minSpan = ((1f / seqLen) * safeScale).coerceAtLeast(MIN_SPAN_RATIO)

                var startRatio = (start.toFloat() / seqLen) * safeScale
                var endRatio = (end.toFloat() / seqLen) * safeScale

                startRatio = startRatio.coerceIn(0f, 1f)
                endRatio = endRatio.coerceIn(startRatio, 1f)

                if (endRatio - startRatio < minSpan) {
                    endRatio = (startRatio + minSpan).coerceAtMost(1f)
                    if (endRatio - startRatio < minSpan) {
                        startRatio = (endRatio - minSpan).coerceAtLeast(0f)
                    }
                }

                spans.add(
                    CharacterSpan(
                        text = character,
                        confidence = meanProb,
                        startRatio = startRatio,
                        endRatio = endRatio
                    )
                )
            }

            t = end
        }

        val text = decodedChars.joinToString("")
        val confidence = if (decodedProbs.isNotEmpty()) {
            decodedProbs.average().toFloat()
        } else {
            0f
        }

        return RecognitionResult(text, confidence, spans)
    }
}
