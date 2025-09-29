package com.example.onnx_ocr_plugin

import android.graphics.Bitmap
import android.graphics.PointF
import ai.onnxruntime.*
import java.nio.FloatBuffer
import kotlin.math.*

class TextDetector(
    private val session: OrtSession,
    private val ortEnv: OrtEnvironment
) {
    companion object {
        private const val LIMIT_SIDE_LEN = 960
        private const val THRESH = 0.3f
        private const val BOX_THRESH = 0.6f
        private const val UNCLIP_RATIO = 1.5f
        private const val MIN_SIZE = 3
    }

    fun detect(bitmap: Bitmap): List<TextBox> {
        val originalWidth = bitmap.width
        val originalHeight = bitmap.height

        // Preprocess image
        val (inputTensor, resizedWidth, resizedHeight) = preprocessImage(bitmap)

        // Run inference
        val inputs = mapOf("x" to inputTensor)
        val outputs = session.run(inputs)
        val output = outputs[0] as OnnxTensor

        // Postprocess to get boxes
        val boxes = postprocessDetection(
            output,
            originalWidth,
            originalHeight,
            resizedWidth,
            resizedHeight
        )

        output.close()
        inputTensor.close()

        return boxes
    }

    private fun preprocessImage(bitmap: Bitmap): Triple<OnnxTensor, Int, Int> {
        val originalWidth = bitmap.width
        val originalHeight = bitmap.height

        // Calculate resize dimensions
        val (resizedWidth, resizedHeight) = calculateResizeDimensions(originalWidth, originalHeight)

        // Resize bitmap
        val resizedBitmap = Bitmap.createScaledBitmap(bitmap, resizedWidth, resizedHeight, true)

        // Convert to float array with normalization
        val inputArray = FloatArray(1 * 3 * resizedHeight * resizedWidth)
        val pixels = IntArray(resizedWidth * resizedHeight)
        resizedBitmap.getPixels(pixels, 0, resizedWidth, 0, 0, resizedWidth, resizedHeight)

        // Normalization parameters from OnnxOCR
        val mean = floatArrayOf(0.485f, 0.456f, 0.406f)
        val std = floatArrayOf(0.229f, 0.224f, 0.225f)
        val scale = 1.0f / 255.0f

        var pixelIndex = 0
        for (y in 0 until resizedHeight) {
            for (x in 0 until resizedWidth) {
                val pixel = pixels[y * resizedWidth + x]
                val r = ((pixel shr 16) and 0xFF) * scale
                val g = ((pixel shr 8) and 0xFF) * scale
                val b = (pixel and 0xFF) * scale

                // CHW format
                inputArray[pixelIndex] = (r - mean[0]) / std[0]
                inputArray[pixelIndex + resizedHeight * resizedWidth] = (g - mean[1]) / std[1]
                inputArray[pixelIndex + 2 * resizedHeight * resizedWidth] = (b - mean[2]) / std[2]
                pixelIndex++
            }
        }

        resizedBitmap.recycle()

        val shape = longArrayOf(1, 3, resizedHeight.toLong(), resizedWidth.toLong())
        val inputTensor = OnnxTensor.createTensor(ortEnv, FloatBuffer.wrap(inputArray), shape)

        return Triple(inputTensor, resizedWidth, resizedHeight)
    }

    private fun calculateResizeDimensions(width: Int, height: Int): Pair<Int, Int> {
        val minSide = min(width, height)
        val ratio = if (minSide < LIMIT_SIDE_LEN) {
            LIMIT_SIDE_LEN.toFloat() / minSide
        } else {
            1.0f
        }

        var resizedWidth = (width * ratio).toInt()
        var resizedHeight = (height * ratio).toInt()

        // Make dimensions multiple of 32
        resizedWidth = max(((resizedWidth + 31) / 32) * 32, 32)
        resizedHeight = max(((resizedHeight + 31) / 32) * 32, 32)

        return Pair(resizedWidth, resizedHeight)
    }

    private fun postprocessDetection(
        output: OnnxTensor,
        originalWidth: Int,
        originalHeight: Int,
        resizedWidth: Int,
        resizedHeight: Int
    ): List<TextBox> {
        val outputArray = output.floatBuffer.array()
        val probMap = Array(resizedHeight) { FloatArray(resizedWidth) }

        // Extract probability map (first channel)
        for (y in 0 until resizedHeight) {
            for (x in 0 until resizedWidth) {
                probMap[y][x] = outputArray[y * resizedWidth + x]
            }
        }

        // Apply threshold to get binary map
        val binaryMap = Array(resizedHeight) { BooleanArray(resizedWidth) }
        for (y in 0 until resizedHeight) {
            for (x in 0 until resizedWidth) {
                binaryMap[y][x] = probMap[y][x] > THRESH
            }
        }

        // Find contours
        val contours = findContours(binaryMap)

        // Convert contours to boxes
        val boxes = mutableListOf<TextBox>()
        val scaleX = originalWidth.toFloat() / resizedWidth
        val scaleY = originalHeight.toFloat() / resizedHeight

        for (contour in contours) {
            // Calculate box score
            val score = calculateBoxScore(probMap, contour)
            if (score < BOX_THRESH) continue

            // Get minimum area rectangle
            val rect = getMinAreaRect(contour)
            if (rect.isEmpty()) continue

            // Scale back to original image size
            val scaledPoints = rect.map { point ->
                PointF(point.x * scaleX, point.y * scaleY)
            }

            // Check minimum size
            val width = distance(scaledPoints[0], scaledPoints[1])
            val height = distance(scaledPoints[0], scaledPoints[3])
            if (width < MIN_SIZE || height < MIN_SIZE) continue

            boxes.add(TextBox(scaledPoints))
        }

        return sortBoxes(boxes)
    }

    private fun findContours(binaryMap: Array<BooleanArray>): List<List<PointF>> {
        // Simplified contour finding - this is a basic implementation
        // In production, you might want to use more sophisticated algorithms
        val contours = mutableListOf<List<PointF>>()
        val visited = Array(binaryMap.size) { BooleanArray(binaryMap[0].size) }

        for (y in binaryMap.indices) {
            for (x in binaryMap[0].indices) {
                if (binaryMap[y][x] && !visited[y][x]) {
                    val contour = traceContour(binaryMap, visited, x, y)
                    if (contour.size >= 4) {
                        contours.add(contour)
                    }
                }
            }
        }

        return contours
    }

    private fun traceContour(
        binaryMap: Array<BooleanArray>,
        visited: Array<BooleanArray>,
        startX: Int,
        startY: Int
    ): List<PointF> {
        val contour = mutableListOf<PointF>()
        val stack = mutableListOf(Pair(startX, startY))
        val points = mutableSetOf<Pair<Int, Int>>()

        while (stack.isNotEmpty()) {
            val (x, y) = stack.removeAt(stack.lastIndex)
            if (x < 0 || x >= binaryMap[0].size || y < 0 || y >= binaryMap.size) continue
            if (!binaryMap[y][x] || visited[y][x]) continue

            visited[y][x] = true
            points.add(Pair(x, y))

            // Check 8 neighbors
            for (dy in -1..1) {
                for (dx in -1..1) {
                    if (dx == 0 && dy == 0) continue
                    stack.add(Pair(x + dx, y + dy))
                }
            }
        }

        // Convert to boundary points
        for ((x, y) in points) {
            var isBoundary = false
            for (dy in -1..1) {
                for (dx in -1..1) {
                    if (dx == 0 && dy == 0) continue
                    val nx = x + dx
                    val ny = y + dy
                    if (nx < 0 || nx >= binaryMap[0].size || ny < 0 || ny >= binaryMap.size || !binaryMap[ny][nx]) {
                        isBoundary = true
                        break
                    }
                }
                if (isBoundary) break
            }
            if (isBoundary) {
                contour.add(PointF(x.toFloat(), y.toFloat()))
            }
        }

        return contour
    }

    private fun calculateBoxScore(probMap: Array<FloatArray>, contour: List<PointF>): Float {
        if (contour.isEmpty()) return 0f

        var minX = contour[0].x.toInt()
        var maxX = minX
        var minY = contour[0].y.toInt()
        var maxY = minY

        for (point in contour) {
            val x = point.x.toInt()
            val y = point.y.toInt()
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        // Clamp to map bounds
        minX = max(0, minX)
        maxX = min(probMap[0].size - 1, maxX)
        minY = max(0, minY)
        maxY = min(probMap.size - 1, maxY)

        // Calculate mean score in bounding box
        var sum = 0f
        var count = 0
        for (y in minY..maxY) {
            for (x in minX..maxX) {
                sum += probMap[y][x]
                count++
            }
        }

        return if (count > 0) sum / count else 0f
    }

    private fun getMinAreaRect(contour: List<PointF>): List<PointF> {
        if (contour.size < 4) return emptyList()

        // Find the convex hull
        val hull = convexHull(contour)
        if (hull.size < 4) return hull

        // For simplicity, return the 4 corners of the bounding box
        // In production, you'd want to implement a proper minimum area rectangle algorithm
        var minX = hull[0].x
        var maxX = minX
        var minY = hull[0].y
        var maxY = minY

        for (point in hull) {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        return listOf(
            PointF(minX, minY),
            PointF(maxX, minY),
            PointF(maxX, maxY),
            PointF(minX, maxY)
        )
    }

    private fun convexHull(points: List<PointF>): List<PointF> {
        if (points.size < 3) return points

        val sorted = points.sortedWith(compareBy({ it.x }, { it.y }))
        val lower = mutableListOf<PointF>()
        val upper = mutableListOf<PointF>()

        for (point in sorted) {
            while (lower.size >= 2 && crossProduct(lower[lower.size - 2], lower[lower.size - 1], point) <= 0) {
                lower.removeAt(lower.lastIndex)
            }
            lower.add(point)
        }

        for (point in sorted.reversed()) {
            while (upper.size >= 2 && crossProduct(upper[upper.size - 2], upper[upper.size - 1], point) <= 0) {
                upper.removeAt(upper.lastIndex)
            }
            upper.add(point)
        }

        lower.removeAt(lower.lastIndex)
        upper.removeAt(upper.lastIndex)
        return lower + upper
    }

    private fun crossProduct(o: PointF, a: PointF, b: PointF): Float {
        return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    private fun distance(p1: PointF, p2: PointF): Float {
        val dx = p2.x - p1.x
        val dy = p2.y - p1.y
        return sqrt(dx * dx + dy * dy)
    }

    private fun sortBoxes(boxes: List<TextBox>): List<TextBox> {
        // Sort boxes from top to bottom, left to right
        return boxes.sortedWith(compareBy(
            { it.points[0].y },
            { it.points[0].x }
        ))
    }
}