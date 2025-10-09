package io.ente.mobile_ocr

import android.graphics.Bitmap
import ai.onnxruntime.*
import java.nio.FloatBuffer
import kotlin.math.*

class TextRecognizer(
    private val session: OrtSession,
    private val ortEnv: OrtEnvironment,
    private val characterDict: List<String>
) {
    companion object {
        private const val IMG_HEIGHT = 48
        private const val IMG_WIDTH = 320
        private const val BATCH_SIZE = 6
    }

    fun recognize(images: List<Bitmap>): List<Pair<String, Float>> {
        if (images.isEmpty()) {
            OcrPerformanceLogger.log("TextRecognizer: no crops to process")
            return emptyList()
        }

        return OcrPerformanceLogger.trace("TextRecognizer#recognize(count=${images.size})") {
            val widthList = images.map { it.width.toFloat() / it.height }
            val sortedIndices = widthList.indices.sortedBy { widthList[it] }
            val orderedResults = MutableList(images.size) { "" to 0f }

            for (start in sortedIndices.indices step BATCH_SIZE) {
                val end = min(start + BATCH_SIZE, sortedIndices.size)
                val batchIndices = sortedIndices.subList(start, end)
                val batchBitmaps = batchIndices.map { images[it] }
                val batchResults = processBatch(batchBitmaps)

                batchIndices.forEachIndexed { idx, originalIndex ->
                    orderedResults[originalIndex] = batchResults[idx]
                }
            }

            OcrPerformanceLogger.log("TextRecognizer: completed recognition for ${images.size} crops")
            orderedResults
        }
    }

    private fun processBatch(batchImages: List<Bitmap>): List<Pair<String, Float>> {
        if (batchImages.isEmpty()) return emptyList()

        return OcrPerformanceLogger.trace("TextRecognizer#processBatch(size=${batchImages.size})") {
            var maxWhRatio = IMG_WIDTH.toFloat() / IMG_HEIGHT
            for (image in batchImages) {
                val ratio = image.width.toFloat() / image.height
                if (ratio > maxWhRatio) {
                    maxWhRatio = ratio
                }
            }

            val targetWidth = ceil(IMG_HEIGHT * maxWhRatio).toInt().coerceAtLeast(1)

            val batchSize = batchImages.size
            val inputArray = FloatArray(batchSize * 3 * IMG_HEIGHT * targetWidth)

            OcrPerformanceLogger.trace("TextRecognizer#prepareBatch(size=$batchSize,width=$targetWidth)") {
                for ((index, image) in batchImages.withIndex()) {
                    preprocessImage(image, inputArray, index, targetWidth)
                }
            }

            val shape = longArrayOf(batchSize.toLong(), 3, IMG_HEIGHT.toLong(), targetWidth.toLong())
            val inputTensor = OnnxTensor.createTensor(ortEnv, FloatBuffer.wrap(inputArray), shape)

            var output: OnnxTensor? = null
            try {
                output = OcrPerformanceLogger.trace("TextRecognizer#runModel(size=$batchSize)") {
                    val inputs = mapOf(session.inputNames.first() to inputTensor)
                    session.run(inputs)[0] as OnnxTensor
                }

                val results = OcrPerformanceLogger.trace("TextRecognizer#decodeOutput(size=$batchSize)") {
                    decodeOutput(output, batchSize)
                }

                OcrPerformanceLogger.log("TextRecognizer: batch size=$batchSize targetWidth=$targetWidth")
                results
            } finally {
                output?.close()
                inputTensor.close()
            }
        }
    }

    private fun preprocessImage(
        bitmap: Bitmap,
        outputArray: FloatArray,
        batchIndex: Int,
        targetWidth: Int
    ) {
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
    }

    private fun decodeOutput(output: OnnxTensor, batchSize: Int): List<Pair<String, Float>> {
        val outputArray = output.floatBuffer.array()
        val shape = output.info.shape
        val seqLen = shape[1].toInt()
        val vocabSize = shape[2].toInt()

        val results = mutableListOf<Pair<String, Float>>()

        for (b in 0 until batchSize) {
            val batchOffset = b * seqLen * vocabSize

            // Get argmax and probabilities for each time step
            val charIndices = mutableListOf<Int>()
            val probs = mutableListOf<Float>()

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

                charIndices.add(maxIndex)
                probs.add(maxProb)
            }

            // CTC decoding with blank removal
            val text = ctcDecode(charIndices, probs)
            results.add(text)
        }

        return results
    }

    private fun ctcDecode(charIndices: List<Int>, probs: List<Float>): Pair<String, Float> {
        val decodedChars = mutableListOf<String>()
        val decodedProbs = mutableListOf<Float>()

        var prevIndex = -1

        for (i in charIndices.indices) {
            val currentIndex = charIndices[i]

            // Skip blank token (index 0) and repeated characters
            if (currentIndex != 0 && currentIndex != prevIndex) {
                if (currentIndex < characterDict.size) {
                    decodedChars.add(characterDict[currentIndex])
                    decodedProbs.add(probs[i])
                }
            }

            prevIndex = currentIndex
        }

        val text = decodedChars.joinToString("")
        val confidence = if (decodedProbs.isNotEmpty()) {
            decodedProbs.average().toFloat()
        } else {
            0f
        }

        return text to confidence
    }
}
