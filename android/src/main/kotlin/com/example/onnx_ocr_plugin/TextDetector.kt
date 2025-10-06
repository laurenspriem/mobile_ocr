package com.example.onnx_ocr_plugin

import android.graphics.Bitmap
import android.graphics.PointF
import ai.onnxruntime.*
import java.nio.FloatBuffer
import java.util.ArrayDeque
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
                val b = (pixel and 0xFF) * scale
                val g = ((pixel shr 8) and 0xFF) * scale
                val r = ((pixel shr 16) and 0xFF) * scale

                // CHW format, BGR order to match PaddleOCR training data
                inputArray[pixelIndex] = (b - mean[0]) / std[0]
                inputArray[pixelIndex + resizedHeight * resizedWidth] = (g - mean[1]) / std[1]
                inputArray[pixelIndex + 2 * resizedHeight * resizedWidth] = (r - mean[2]) / std[2]
                pixelIndex++
            }
        }

        resizedBitmap.recycle()

        val shape = longArrayOf(1, 3, resizedHeight.toLong(), resizedWidth.toLong())
        val inputTensor = OnnxTensor.createTensor(ortEnv, FloatBuffer.wrap(inputArray), shape)

        return Triple(inputTensor, resizedWidth, resizedHeight)
    }

    private fun calculateResizeDimensions(width: Int, height: Int): Pair<Int, Int> {
        val maxSide = max(width, height)
        val ratio = if (maxSide > LIMIT_SIDE_LEN) {
            LIMIT_SIDE_LEN.toFloat() / maxSide
        } else {
            1.0f
        }

        var resizedWidth = max(1, (width * ratio).roundToInt())
        var resizedHeight = max(1, (height * ratio).roundToInt())

        // Make dimensions multiple of 32 (minimum 32)
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

        val components = extractConnectedComponents(binaryMap)
        val boxes = mutableListOf<TextBox>()
        val scaleX = originalWidth.toFloat() / resizedWidth
        val scaleY = originalHeight.toFloat() / resizedHeight

        for (component in components) {
            if (component.size < 4) continue

            val hull = convexHull(component)
            if (hull.size < 3) continue

            val rect = minimumAreaRectangle(hull, pointsAreConvex = true)
            if (rect.isEmpty()) continue

            val score = calculateBoxScore(probMap, rect)
            if (score < BOX_THRESH) continue

            val unclippedRect = unclipBox(rect, UNCLIP_RATIO)
            if (unclippedRect.isEmpty()) continue

            val clippedRect = ImageUtils.clipBoxToImageBounds(unclippedRect, resizedWidth, resizedHeight)
            val minSide = getMinSide(clippedRect)
            if (minSide < MIN_SIZE) continue

            val scaledPoints = clippedRect.map { point ->
                PointF(point.x * scaleX, point.y * scaleY)
            }

            val orderedPoints = ImageUtils.orderPointsClockwise(scaledPoints)
            boxes.add(TextBox(orderedPoints))
        }

        return sortBoxes(boxes)
    }
    private fun extractConnectedComponents(binaryMap: Array<BooleanArray>): List<List<PointF>> {
        val height = binaryMap.size
        val width = if (height > 0) binaryMap[0].size else 0
        val visited = Array(height) { BooleanArray(width) }
        val components = mutableListOf<List<PointF>>()
        val stack = ArrayDeque<Pair<Int, Int>>()

        for (y in 0 until height) {
            for (x in 0 until width) {
                if (!binaryMap[y][x] || visited[y][x]) continue

                val points = mutableListOf<PointF>()
                stack.clear()
                stack.add(Pair(x, y))
                visited[y][x] = true

                while (stack.isNotEmpty()) {
                    val (cx, cy) = stack.removeLast()
                    points.add(PointF(cx.toFloat(), cy.toFloat()))

                    for (dy in -1..1) {
                        for (dx in -1..1) {
                            if (dx == 0 && dy == 0) continue
                            val nx = cx + dx
                            val ny = cy + dy
                            if (nx in 0 until width && ny in 0 until height &&
                                binaryMap[ny][nx] && !visited[ny][nx]
                            ) {
                                visited[ny][nx] = true
                                stack.add(Pair(nx, ny))
                            }
                        }
                    }
                }

                components.add(points)
            }
        }

        return components
    }

    private fun calculateBoxScore(probMap: Array<FloatArray>, polygon: List<PointF>): Float {
        if (polygon.isEmpty()) return 0f

        var minX = floor(polygon.minOf { it.x.toDouble() }).toInt()
        var maxX = ceil(polygon.maxOf { it.x.toDouble() }).toInt()
        var minY = floor(polygon.minOf { it.y.toDouble() }).toInt()
        var maxY = ceil(polygon.maxOf { it.y.toDouble() }).toInt()

        minX = min(max(minX, 0), probMap[0].size - 1)
        maxX = min(max(maxX, 0), probMap[0].size - 1)
        minY = min(max(minY, 0), probMap.size - 1)
        maxY = min(max(maxY, 0), probMap.size - 1)

        if (maxX < minX || maxY < minY) return 0f

        var sum = 0f
        var count = 0

        for (y in minY..maxY) {
            for (x in minX..maxX) {
                if (isPointInsideQuad(x + 0.5f, y + 0.5f, polygon)) {
                    sum += probMap[y][x]
                    count++
                }
            }
        }

        return if (count > 0) sum / count else 0f
    }

    private fun minimumAreaRectangle(points: List<PointF>, pointsAreConvex: Boolean = false): List<PointF> {
        val hull = if (pointsAreConvex) points else convexHull(points)
        if (hull.size < 3) return emptyList()

        var bestRect: List<PointF> = emptyList()
        var minArea = Float.MAX_VALUE

        for (i in hull.indices) {
            val p1 = hull[i]
            val p2 = hull[(i + 1) % hull.size]
            val edgeVec = normalizeVector(p1, p2) ?: continue
            val normal = PointF(-edgeVec.y, edgeVec.x)

            var minProj = Float.MAX_VALUE
            var maxProj = -Float.MAX_VALUE
            var minOrth = Float.MAX_VALUE
            var maxOrth = -Float.MAX_VALUE

            for (pt in hull) {
                val relX = pt.x - p1.x
                val relY = pt.y - p1.y
                val projection = relX * edgeVec.x + relY * edgeVec.y
                val orthProjection = relX * normal.x + relY * normal.y

                if (projection < minProj) minProj = projection
                if (projection > maxProj) maxProj = projection
                if (orthProjection < minOrth) minOrth = orthProjection
                if (orthProjection > maxOrth) maxOrth = orthProjection
            }

            val width = maxProj - minProj
            val height = maxOrth - minOrth
            val area = width * height

            if (area < minArea && width > 1e-3f && height > 1e-3f) {
                minArea = area

                val corner0 = PointF(
                    p1.x + edgeVec.x * minProj + normal.x * minOrth,
                    p1.y + edgeVec.y * minProj + normal.y * minOrth
                )
                val corner1 = PointF(
                    p1.x + edgeVec.x * maxProj + normal.x * minOrth,
                    p1.y + edgeVec.y * maxProj + normal.y * minOrth
                )
                val corner2 = PointF(
                    p1.x + edgeVec.x * maxProj + normal.x * maxOrth,
                    p1.y + edgeVec.y * maxProj + normal.y * maxOrth
                )
                val corner3 = PointF(
                    p1.x + edgeVec.x * minProj + normal.x * maxOrth,
                    p1.y + edgeVec.y * minProj + normal.y * maxOrth
                )

                bestRect = listOf(corner0, corner1, corner2, corner3)
            }
        }

        return if (bestRect.isEmpty()) axisAlignedBoundingBox(hull) else bestRect
    }

    private fun normalizeVector(from: PointF, to: PointF): PointF? {
        val dx = to.x - from.x
        val dy = to.y - from.y
        val length = sqrt(dx * dx + dy * dy)
        if (length < 1e-6f) return null
        return PointF(dx / length, dy / length)
    }

    private fun axisAlignedBoundingBox(points: List<PointF>): List<PointF> {
        if (points.isEmpty()) return emptyList()

        var minX = Float.MAX_VALUE
        var maxX = -Float.MAX_VALUE
        var minY = Float.MAX_VALUE
        var maxY = -Float.MAX_VALUE

        for (point in points) {
            if (point.x < minX) minX = point.x
            if (point.x > maxX) maxX = point.x
            if (point.y < minY) minY = point.y
            if (point.y > maxY) maxY = point.y
        }

        return listOf(
            PointF(minX, minY),
            PointF(maxX, minY),
            PointF(maxX, maxY),
            PointF(minX, maxY)
        )
    }

    private fun isPointInsideQuad(x: Float, y: Float, quad: List<PointF>): Boolean {
        if (quad.size < 3) return false

        var hasPositive = false
        var hasNegative = false

        for (i in quad.indices) {
            val p1 = quad[i]
            val p2 = quad[(i + 1) % quad.size]
            val cross = (p2.x - p1.x) * (y - p1.y) - (p2.y - p1.y) * (x - p1.x)
            if (cross > 0) hasPositive = true else if (cross < 0) hasNegative = true
            if (hasPositive && hasNegative) return false
        }

        return true
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
        if (boxes.isEmpty()) return emptyList()

        val sortedByTop = boxes.sortedBy { box ->
            box.points.minOf { it.y }
        }

        val ordered = mutableListOf<TextBox>()
        var index = 0
        while (index < sortedByTop.size) {
            val current = sortedByTop[index]
            val referenceY = current.points.minOf { it.y }
            val group = mutableListOf<TextBox>()

            var j = index
            while (j < sortedByTop.size) {
                val candidate = sortedByTop[j]
                val candidateY = candidate.points.minOf { it.y }
                if (abs(candidateY - referenceY) <= 10f) {
                    group.add(candidate)
                    j++
                } else {
                    break
                }
            }

            group.sortBy { box -> box.points.minOf { it.x } }
            ordered.addAll(group)
            index = j
        }

        return ordered
    }

    private fun unclipBox(box: List<PointF>, unclipRatio: Float): List<PointF> {
        if (box.size != 4) return emptyList()

        val width = distance(box[0], box[1])
        val height = distance(box[0], box[3])
        if (width <= 0f || height <= 0f) return emptyList()

        val area = width * height
        val perimeter = 2f * (width + height)
        if (perimeter <= 1e-6f) return box

        val offset = area * unclipRatio / perimeter
        val newWidth = width + 2f * offset
        val newHeight = height + 2f * offset

        val centerX = box.sumOf { it.x.toDouble() }.toFloat() / box.size
        val centerY = box.sumOf { it.y.toDouble() }.toFloat() / box.size

        val xAxis = normalizeVector(box[0], box[1]) ?: return emptyList()
        val yAxis = normalizeVector(box[0], box[3]) ?: return emptyList()

        val halfWidth = newWidth / 2f
        val halfHeight = newHeight / 2f

        val corner0 = PointF(
            centerX - xAxis.x * halfWidth - yAxis.x * halfHeight,
            centerY - xAxis.y * halfWidth - yAxis.y * halfHeight
        )
        val corner1 = PointF(
            centerX + xAxis.x * halfWidth - yAxis.x * halfHeight,
            centerY + xAxis.y * halfWidth - yAxis.y * halfHeight
        )
        val corner2 = PointF(
            centerX + xAxis.x * halfWidth + yAxis.x * halfHeight,
            centerY + xAxis.y * halfWidth + yAxis.y * halfHeight
        )
        val corner3 = PointF(
            centerX - xAxis.x * halfWidth + yAxis.x * halfHeight,
            centerY - xAxis.y * halfWidth + yAxis.y * halfHeight
        )

        return listOf(corner0, corner1, corner2, corner3)
    }

    private fun getMinSide(box: List<PointF>): Float {
        if (box.size < 4) return 0f
        val width1 = distance(box[0], box[1])
        val width2 = distance(box[2], box[3])
        val height1 = distance(box[0], box[3])
        val height2 = distance(box[1], box[2])
        return min(min(width1, width2), min(height1, height2))
    }
}
