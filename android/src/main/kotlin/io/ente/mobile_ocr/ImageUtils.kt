package io.ente.mobile_ocr

import android.graphics.*
import kotlin.math.*

object ImageUtils {

    fun cropTextRegion(bitmap: Bitmap, points: List<PointF>): Bitmap {
        if (points.size != 4) {
            throw IllegalArgumentException("Expected 4 points for text region")
        }

        // Calculate dimensions of the cropped region
        // Use maximum of opposing sides to avoid truncation (matching Python implementation)
        val width = max(
            distance(points[0], points[1]),  // top edge
            distance(points[2], points[3])   // bottom edge
        ).toInt().coerceAtLeast(1)
        val height = max(
            distance(points[0], points[3]),  // left edge
            distance(points[1], points[2])   // right edge
        ).toInt().coerceAtLeast(1)

        // Create destination points for perspective transform
        val dstPoints = floatArrayOf(
            0f, 0f,
            width.toFloat(), 0f,
            width.toFloat(), height.toFloat(),
            0f, height.toFloat()
        )

        // Create source points
        val srcPoints = floatArrayOf(
            points[0].x, points[0].y,
            points[1].x, points[1].y,
            points[2].x, points[2].y,
            points[3].x, points[3].y
        )

        // Calculate perspective transform matrix
        val matrix = Matrix()
        matrix.setPolyToPoly(srcPoints, 0, dstPoints, 0, 4)

        val inverse = Matrix()
        if (!matrix.invert(inverse)) {
            throw IllegalStateException("Failed to invert perspective transform matrix")
        }

        val croppedBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(width * height)
        val mappedPoint = FloatArray(2)

        for (y in 0 until height) {
            for (x in 0 until width) {
                mappedPoint[0] = x + 0.5f
                mappedPoint[1] = y + 0.5f
                inverse.mapPoints(mappedPoint)

                pixels[y * width + x] = sampleBicubic(bitmap, mappedPoint[0], mappedPoint[1])
            }
        }

        croppedBitmap.setPixels(pixels, 0, width, 0, 0, width, height)

        // Check if the image needs rotation based on aspect ratio
        if (height.toFloat() / width >= 1.5f) {
            val rotationMatrix = Matrix().apply {
                postRotate(90f)
            }
            return Bitmap.createBitmap(
                croppedBitmap,
                0,
                0,
                croppedBitmap.width,
                croppedBitmap.height,
                rotationMatrix,
                true
            )
        }

        return croppedBitmap
    }

    fun orderPointsClockwise(points: List<PointF>): List<PointF> {
        if (points.size != 4) {
            return points
        }

        // Calculate center point
        val centerX = points.sumOf { it.x.toDouble() }.toFloat() / 4
        val centerY = points.sumOf { it.y.toDouble() }.toFloat() / 4

        // Sort points by angle from center
        val sortedPoints = points.sortedBy { point ->
            atan2(
                (point.y - centerY).toDouble(),
                (point.x - centerX).toDouble()
            )
        }

        // Find top-left point (minimum sum of x and y)
        var topLeftIndex = 0
        var minSum = sortedPoints[0].x + sortedPoints[0].y
        for (i in 1 until 4) {
            val sum = sortedPoints[i].x + sortedPoints[i].y
            if (sum < minSum) {
                minSum = sum
                topLeftIndex = i
            }
        }

        // Reorder starting from top-left
        val orderedPoints = mutableListOf<PointF>()
        for (i in 0 until 4) {
            orderedPoints.add(sortedPoints[(topLeftIndex + i) % 4])
        }

        return orderedPoints
    }

    fun distance(p1: PointF, p2: PointF): Float {
        val dx = p2.x - p1.x
        val dy = p2.y - p1.y
        return sqrt(dx * dx + dy * dy)
    }

    fun expandBox(points: List<PointF>, expandRatio: Float = 1.5f): List<PointF> {
        if (points.size != 4) {
            return points
        }

        // Calculate center
        val centerX = points.sumOf { it.x.toDouble() }.toFloat() / 4
        val centerY = points.sumOf { it.y.toDouble() }.toFloat() / 4

        // Expand each point from center
        return points.map { point ->
            val dx = point.x - centerX
            val dy = point.y - centerY
            PointF(
                centerX + dx * expandRatio,
                centerY + dy * expandRatio
            )
        }
    }

    fun clipBoxToImageBounds(
        points: List<PointF>,
        imageWidth: Int,
        imageHeight: Int
    ): List<PointF> {
        return points.map { point ->
            PointF(
                point.x.coerceIn(0f, imageWidth - 1f),
                point.y.coerceIn(0f, imageHeight - 1f)
            )
        }
    }

    fun calculateBoxArea(points: List<PointF>): Float {
        if (points.size != 4) {
            return 0f
        }

        // Shoelace formula for quadrilateral area
        var area = 0f
        for (i in points.indices) {
            val j = (i + 1) % points.size
            area += points[i].x * points[j].y
            area -= points[j].x * points[i].y
        }
        return abs(area) / 2f
    }

    fun isValidBox(points: List<PointF>, minWidth: Float = 3f, minHeight: Float = 3f): Boolean {
        if (points.size != 4) {
            return false
        }

        val width = distance(points[0], points[1])
        val height = distance(points[0], points[3])

        return width >= minWidth && height >= minHeight
    }
}

private fun sampleBicubic(bitmap: Bitmap, x: Float, y: Float): Int {
    val width = bitmap.width
    val height = bitmap.height

    val clampedX = x.coerceIn(0f, width - 1f)
    val clampedY = y.coerceIn(0f, height - 1f)

    val xBase = floor(clampedX).toInt()
    val yBase = floor(clampedY).toInt()
    val tx = clampedX - xBase
    val ty = clampedY - yBase

    val intermediate = Array(4) { FloatArray(4) }

    for (row in -1..2) {
        val sampleY = (yBase + row).coerceIn(0, height - 1)
        val rowIndex = row + 1
        val channelSamples = Array(4) { FloatArray(4) }
        for (col in -1..2) {
            val sampleX = (xBase + col).coerceIn(0, width - 1)
            val pixel = bitmap.getPixel(sampleX, sampleY)
            val columnIndex = col + 1
            channelSamples[0][columnIndex] = (pixel and 0xFF).toFloat()
            channelSamples[1][columnIndex] = ((pixel shr 8) and 0xFF).toFloat()
            channelSamples[2][columnIndex] = ((pixel shr 16) and 0xFF).toFloat()
            channelSamples[3][columnIndex] = (pixel ushr 24).toFloat()
        }
        for (channel in 0 until 4) {
            intermediate[channel][rowIndex] = cubicHermite(
                channelSamples[channel][0],
                channelSamples[channel][1],
                channelSamples[channel][2],
                channelSamples[channel][3],
                tx
            )
        }
    }

    val resultChannels = FloatArray(4)
    for (channel in 0 until 4) {
        resultChannels[channel] = cubicHermite(
            intermediate[channel][0],
            intermediate[channel][1],
            intermediate[channel][2],
            intermediate[channel][3],
            ty
        ).coerceIn(0f, 255f)
    }

    val b = resultChannels[0].roundToInt()
    val g = resultChannels[1].roundToInt()
    val r = resultChannels[2].roundToInt()
    val a = resultChannels[3].roundToInt()

    return (a shl 24) or (r shl 16) or (g shl 8) or b
}

private fun cubicHermite(p0: Float, p1: Float, p2: Float, p3: Float, t: Float): Float {
    val a = -0.5f * p0 + 1.5f * p1 - 1.5f * p2 + 0.5f * p3
    val b = p0 - 2.5f * p1 + 2f * p2 - 0.5f * p3
    val c = -0.5f * p0 + 0.5f * p2
    val d = p1
    return ((a * t + b) * t + c) * t + d
}
