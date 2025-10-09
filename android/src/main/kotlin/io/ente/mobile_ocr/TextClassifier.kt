package io.ente.mobile_ocr

import android.graphics.Bitmap
import android.graphics.Matrix
import ai.onnxruntime.*
import java.nio.FloatBuffer
import kotlin.math.ceil
import kotlin.math.roundToInt

data class ClassificationOutput(
    val bitmap: Bitmap,
    val rotated: Boolean
)

class TextClassifier(
    private val session: OrtSession,
    private val ortEnv: OrtEnvironment
) {
    companion object {
        private const val IMG_HEIGHT = 48
        private const val IMG_WIDTH = 192
        private const val CLS_THRESH = 0.9f
        private const val BATCH_SIZE = 6
    }

    fun classifyAndRotate(images: List<Bitmap>): List<ClassificationOutput> {
        val results = mutableListOf<ClassificationOutput>()

        // Process in batches
        for (i in images.indices step BATCH_SIZE) {
            val batchEnd = minOf(i + BATCH_SIZE, images.size)
            val batch = images.subList(i, batchEnd)

            val rotationFlags = classifyBatch(batch)

            // Apply rotations
            for (j in batch.indices) {
                val image = batch[j]
                val shouldRotate = rotationFlags[j]

                results.add(
                    if (shouldRotate) {
                        ClassificationOutput(rotateImage180(image), true)
                    } else {
                        ClassificationOutput(image, false)
                    }
                )
            }
        }

        return results
    }

    private fun classifyBatch(batchImages: List<Bitmap>): List<Boolean> {
        if (batchImages.isEmpty()) return emptyList()

        val batchSize = batchImages.size
        val inputArray = FloatArray(batchSize * 3 * IMG_HEIGHT * IMG_WIDTH)

        // Preprocess all images
        for ((index, image) in batchImages.withIndex()) {
            preprocessImage(image, inputArray, index)
        }

        // Create tensor
        val shape = longArrayOf(batchSize.toLong(), 3, IMG_HEIGHT.toLong(), IMG_WIDTH.toLong())
        val inputTensor = OnnxTensor.createTensor(ortEnv, FloatBuffer.wrap(inputArray), shape)

        // Run inference
        val inputs = mapOf(session.inputNames.first() to inputTensor)
        val outputs = session.run(inputs)
        val output = outputs[0] as OnnxTensor

        // Decode results
        val results = decodeOutput(output, batchSize)

        output.close()
        inputTensor.close()

        return results
    }

    private fun preprocessImage(
        bitmap: Bitmap,
        outputArray: FloatArray,
        batchIndex: Int
    ) {
        // Calculate resize dimensions maintaining aspect ratio
        val aspectRatio = bitmap.width.toFloat() / bitmap.height
        val resizedWidth = minOf(
            ceil(IMG_HEIGHT * aspectRatio).toInt().coerceAtLeast(1),
            IMG_WIDTH
        )

        // Resize bitmap
        val resizedBitmap = Bitmap.createScaledBitmap(bitmap, resizedWidth, IMG_HEIGHT, true)

        // Get pixels
        val pixels = IntArray(resizedWidth * IMG_HEIGHT)
        resizedBitmap.getPixels(pixels, 0, resizedWidth, 0, 0, resizedWidth, IMG_HEIGHT)
        resizedBitmap.recycle()

        // Normalize and convert to CHW format
        val baseOffset = batchIndex * 3 * IMG_HEIGHT * IMG_WIDTH

        val channelStride = IMG_HEIGHT * IMG_WIDTH

        for (y in 0 until IMG_HEIGHT) {
            val rowOffset = y * IMG_WIDTH
            val sourceRowOffset = y * resizedWidth

            for (x in 0 until IMG_WIDTH) {
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

    private fun decodeOutput(output: OnnxTensor, batchSize: Int): List<Boolean> {
        val outputArray = output.floatBuffer.array()
        val results = mutableListOf<Boolean>()

        // Output shape should be [batch_size, 2] where 2 classes are ["0", "180"]
        for (b in 0 until batchSize) {
            val baseOffset = b * 2
            val prob0 = outputArray[baseOffset]
            val prob180 = outputArray[baseOffset + 1]

            // Check if image is rotated 180 degrees
            val shouldRotate = prob180 > prob0 && prob180 > CLS_THRESH

            results.add(shouldRotate)
        }

        return results
    }

    private fun rotateImage180(bitmap: Bitmap): Bitmap {
        val matrix = Matrix().apply {
            postRotate(180f)
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }
}
