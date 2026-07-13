import Foundation
import Vision
import AppKit
import CoreImage

let imagePath = CommandLine.arguments[1]
let url = URL(fileURLWithPath: imagePath)

// ─── Image Loading & Preprocessing ───

guard let image = NSImage(contentsOf: url),
      let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      var cgImage = bitmap.cgImage else {
    print("ERROR: Cannot load image")
    exit(1)
}

func log(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

// Preprocessing: enhance contrast for better OCR
let ciImage = CIImage(cgImage: cgImage)
let filters = ciImage
    .applyingFilter("CIColorControls", parameters: [
        kCIInputContrastKey: 1.15,
        kCIInputBrightnessKey: 0.02,
        kCIInputSaturationKey: 0.0
    ])
    .applyingFilter("CIUnsharpMask", parameters: [
        kCIInputRadiusKey: 1.5,
        kCIInputIntensityKey: 0.6
    ])

let ctx = CIContext(options: [.useSoftwareRenderer: false])
if let filtered = ctx.createCGImage(filters, from: filters.extent) {
    cgImage = filtered
    log("Image preprocessing applied (contrast + sharpen)")
}

let imgWidth = CGFloat(cgImage.width)
let imgHeight = CGFloat(cgImage.height)

// ─── Step 1: Collect ALL text observations ───

struct TextItem {
    let text: String
    let cx: CGFloat       // center X (normalized 0-1)
    let left: CGFloat     // left edge X
    let right: CGFloat    // right edge X
    let absY: CGFloat     // center Y (normalized 0=top, 1=bottom)
    let top: CGFloat      // top edge Y
    let bottom: CGFloat   // bottom edge Y
    let h: CGFloat        // height
}

var allItems: [TextItem] = []
let chunkH: CGFloat = 3000
let numChunks = Int(ceil(imgHeight / chunkH))

for i in 0..<numChunks {
    let y = imgHeight - CGFloat(i + 1) * chunkH
    let cropY = max(0, y)
    let cropH = min(chunkH, imgHeight - cropY)
    let cropRect = CGRect(x: 0, y: cropY, width: imgWidth, height: cropH)

    guard let cropped = cgImage.cropping(to: cropRect) else { continue }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en"]
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.005  // Filter out tiny noise

    let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
    do {
        try handler.perform([request])
        guard let observations = request.results else { continue }
        for obs in observations {
            guard let text = obs.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let bb = obs.boundingBox
            // Convert Vision coordinates (bottom-left origin) to top-left origin, normalized
            let normX = bb.origin.x
            let normY = (cropY + bb.origin.y * cropH) / imgHeight  // top of box in image coords
            let normH = bb.height * cropH / imgHeight
            let normW = bb.width
            let absY = normY + normH / 2  // center Y (0=top, 1=bottom)

            allItems.append(TextItem(
                text: text,
                cx: normX + normW / 2,
                left: normX,
                right: normX + normW,
                absY: absY,
                top: normY,
                bottom: normY + normH,
                h: normH
            ))
        }
    } catch {}
}

log("Total items: \(allItems.count), Image: \(Int(imgWidth))x\(Int(imgHeight))")

guard allItems.count >= 3 else {
    for item in allItems {
        print(item.text)
    }
    exit(0)
}

// Sort by Y position
allItems.sort { a, b in
    if abs(a.absY - b.absY) > 0.0005 { return a.absY < b.absY }
    return a.cx < b.cx
}

// ─── Step 2: Histogram-based Row Detection ───

let heights = allItems.map { $0.h }.sorted()
let medianH = heights.count > 0 ? heights[heights.count / 2] : 0.015
let iqrH = heights.count > 4
    ? (heights[heights.count * 3 / 4] - heights[heights.count / 4])
    : medianH * 0.5

log("Median height: \(String(format: "%.4f", medianH)), IQR: \(String(format: "%.4f", iqrH))")

// Kernel Density Estimation for row detection
// Place a Gaussian kernel at each item's Y center, then find peaks & valleys
let densityBins = 500
var density = [Double](repeating: 0, count: densityBins)
let kernelSigma = Double(medianH) * Double(densityBins) * 0.35  // adaptive sigma (narrow kernel = better row separation)

for item in allItems {
    let center = Int(item.absY * Double(densityBins))
    let radius = Int(kernelSigma * 3.0)
    for offset in -radius...radius {
        let bin = center + offset
        guard bin >= 0 && bin < densityBins else { continue }
        let x = Double(offset) / kernelSigma
        density[bin] += exp(-0.5 * x * x)
    }
}

// Find local maxima (row centers) - peaks above noise floor
let densityMean = density.reduce(0, +) / Double(densityBins)
let densityStd = sqrt(density.map { ($0 - densityMean) * ($0 - densityMean) }.reduce(0, +) / Double(densityBins))
let peakThreshold = densityMean + densityStd * 0.3

var peaks: [Int] = []
var inPeak = false
var peakStart = 0

for i in 0..<densityBins {
    if density[i] >= peakThreshold && !inPeak {
        inPeak = true
        peakStart = i
    } else if density[i] < peakThreshold && inPeak {
        inPeak = false
        let peakCenter = (peakStart + i - 1) / 2
        if peaks.isEmpty || (peakCenter - peaks.last!) > 3 {
            peaks.append(peakCenter)
        }
    }
}
if inPeak {
    let peakCenter = (peakStart + densityBins - 1) / 2
    if peaks.isEmpty || (peakCenter - peaks.last!) > 3 {
        peaks.append(peakCenter)
    }
}

// Find valleys (row boundaries) as midpoints between density peaks
var boundaries: [CGFloat] = [0.0]
for i in 0..<(peaks.count - 1) {
    let mid = CGFloat(peaks[i] + peaks[i+1]) / (2.0 * CGFloat(densityBins))
    boundaries.append(mid)
}
boundaries.append(1.0)

// Merge boundaries that are too close
var merged: [CGFloat] = [0.0]
for i in 1..<(boundaries.count - 1) {
    let prev = merged.last!
    if boundaries[i] - prev < medianH * 0.3 {
        continue
    }
    merged.append(boundaries[i])
}
merged.append(1.0)

log("Detected \(merged.count - 1) rows via KDE (peaks: \(peaks.count))")

// Assign items to rows
struct Row {
    var items: [TextItem]
    var yMin: CGFloat
    var yMax: CGFloat
}

var detectedRows: [Row] = []
for i in 0..<(merged.count - 1) {
    let y0 = merged[i]
    let y1 = merged[i + 1]
    var rowItems: [TextItem] = []
    for item in allItems {
        // Item's center must be within the row bounds
        if item.absY >= y0 && item.absY < y1 {
            rowItems.append(item)
        }
    }
    if !rowItems.isEmpty {
        rowItems.sort { $0.cx < $1.cx }
        detectedRows.append(Row(items: rowItems, yMin: y0, yMax: y1))
    }
}

log("Non-empty rows: \(detectedRows.count)")

// ─── Step 3: K-Means Column Detection ───

// Collect all X-center positions (weighted — each text item)
var xPositions: [CGFloat] = []
for row in detectedRows {
    for item in row.items {
        xPositions.append(item.cx)
    }
}

// Try different K values and pick the best using elbow method
func kmeans(data: [CGFloat], k: Int, maxIter: Int = 30) -> ([Int], [CGFloat]) {
    guard data.count >= k, k > 0 else { return ([], []) }

    // Initialize centroids evenly spaced
    let sorted = data.sorted()
    var centroids: [CGFloat] = []
    for i in 0..<k {
        let idx = i * (sorted.count - 1) / max(k - 1, 1)
        centroids.append(sorted[idx])
    }

    var assignments = [Int](repeating: 0, count: data.count)

    for _ in 0..<maxIter {
        // Assign each point to nearest centroid
        var changed = false
        for i in 0..<data.count {
            var bestDist = CGFloat.infinity
            var bestCluster = 0
            for c in 0..<k {
                let dist = abs(data[i] - centroids[c])
                if dist < bestDist {
                    bestDist = dist
                    bestCluster = c
                }
            }
            if assignments[i] != bestCluster {
                assignments[i] = bestCluster
                changed = true
            }
        }
        if !changed { break }

        // Update centroids
        var sums = [CGFloat](repeating: 0, count: k)
        var counts = [Int](repeating: 0, count: k)
        for i in 0..<data.count {
            sums[assignments[i]] += data[i]
            counts[assignments[i]] += 1
        }
        for c in 0..<k {
            if counts[c] > 0 { centroids[c] = sums[c] / CGFloat(counts[c]) }
        }
    }

    return (assignments, centroids)
}

func calculateWSS(data: [CGFloat], assignments: [Int], centroids: [CGFloat]) -> Double {
    var wss: Double = 0
    for i in 0..<data.count {
        let dx = Double(data[i] - centroids[assignments[i]])
        wss += dx * dx
    }
    return wss
}

// Determine optimal K using elbow method (simplified)
let maxK = min(12, xPositions.count / 3)
var bestK = 2
var bestScore: Double = -.infinity

guard maxK >= 2 else {
    // Too few items, single column
    for row in detectedRows {
        print(row.items.map { $0.text }.joined(separator: "\t"))
    }
    exit(0)
}

var wssValues: [Double] = []
for k in 2...maxK {
    let (assignments, centroids) = kmeans(data: xPositions, k: k)
    guard !centroids.isEmpty else { continue }
    let wss = calculateWSS(data: xPositions, assignments: assignments, centroids: centroids)
    wssValues.append(wss)
}

// Elbow detection: find point where the rate of improvement drops most
if wssValues.count >= 3 {
    var maxGap: Double = 0
    for i in 1..<(wssValues.count - 1) {
        let improvement1 = wssValues[i-1] - wssValues[i]
        let improvement2 = wssValues[i] - wssValues[i+1]
        let gap = improvement1 - improvement2
        if gap > maxGap {
            maxGap = gap
            bestK = i + 2  // +2 because i=0 corresponds to k=2
        }
    }
}

log("K-Means detected \(bestK) columns (k range 2-\(maxK))")

// Run final K-means with best K
let (_, centroids) = kmeans(data: xPositions, k: bestK)
let sortedCentroids = centroids.sorted()

// Derive column boundaries as midpoints between adjacent cluster centers
var colBounds: [CGFloat] = [0.0]
for i in 0..<(sortedCentroids.count - 1) {
    let mid = (sortedCentroids[i] + sortedCentroids[i+1]) / 2.0
    colBounds.append(mid)
}
colBounds.append(1.0)

log("Column boundaries: \(colBounds.map { String(format: "%.3f", $0) })")

let numCols = colBounds.count - 1

// ─── Step 4: Grid Assignment & Multi-line Merging ───

struct Cell {
    var texts: [String] = []
}

var tableRows: [[Cell]] = []

for row in detectedRows {
    var cells = [Cell](repeating: Cell(), count: numCols)
    for item in row.items {
        var col = numCols - 1
        for c in 0..<numCols {
            if item.cx < colBounds[c + 1] {
                col = c
                break
            }
        }
        cells[col].texts.append(item.text)
    }
    // Deduplicate within same cell (Vision sometimes returns duplicates)
    for c in 0..<numCols {
        cells[c].texts = Array(Set(cells[c].texts))
    }
    let hasContent = cells.contains { !$0.texts.isEmpty }
    if hasContent {
        tableRows.append(cells)
    }
}

// Merge multi-line rows: if a row has content only in some columns,
// merge it into the previous row's corresponding columns
var mergedRows: [[Cell]] = []
for row in tableRows {
    let emptyFirstCol = numCols > 0 && row[0].texts.isEmpty
    let allColsEmpty = row.allSatisfy { $0.texts.isEmpty }

    if emptyFirstCol && !allColsEmpty && !mergedRows.isEmpty {
        // Continuation row: merge into previous
        let prevIdx = mergedRows.count - 1
        for c in 0..<numCols {
            if !row[c].texts.isEmpty {
                mergedRows[prevIdx][c].texts.append(contentsOf: row[c].texts)
            }
        }
    } else if !allColsEmpty {
        mergedRows.append(row)
    }
}

// Also pre-merge: check adjacent rows where column 1+ are empty (likely merged cells)
// Actually, don't pre-merge too aggressively — the histogram already handles rows well

log("Final table: \(mergedRows.count) rows × \(numCols) cols")

// ─── Step 5: Output ───
for row in mergedRows {
    let cellStrings = row.map { cell in
        let cleaned = cell.texts.map {
            $0.replacingOccurrences(of: "\n", with: " ")
              .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return cleaned.joined(separator: "\\n")
    }
    print(cellStrings.joined(separator: "\t"))
}
