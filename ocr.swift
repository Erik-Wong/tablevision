import Foundation
import Vision
import AppKit

let imagePath = CommandLine.arguments[1]
let url = URL(fileURLWithPath: imagePath)

guard let image = NSImage(contentsOf: url),
      let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let fullCgImage = bitmap.cgImage else {
    print("ERROR: Cannot load image")
    exit(1)
}

let imgWidth = CGFloat(fullCgImage.width)
let imgHeight = CGFloat(fullCgImage.height)

func log(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

// ─── Step 1: Collect ALL text observations from all chunks ───
struct TextItem {
    let text: String
    let cx: CGFloat
    let left: CGFloat
    let right: CGFloat
    let absY: CGFloat
    let h: CGFloat
}

var allItems: [TextItem] = []
let chunkH: CGFloat = 3000
let numChunks = Int(ceil(imgHeight / chunkH))

for i in 0..<numChunks {
    let y = imgHeight - CGFloat(i + 1) * chunkH
    let cropY = max(0, y)
    let cropH = min(chunkH, imgHeight - cropY)
    let cropRect = CGRect(x: 0, y: cropY, width: imgWidth, height: cropH)

    guard let cropped = fullCgImage.cropping(to: cropRect) else { continue }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en"]
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
    do {
        try handler.perform([request])
        guard let observations = request.results else { continue }
        for obs in observations {
            guard let text = obs.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let bb = obs.boundingBox
            let absY = ((1.0 - (bb.origin.y + bb.height / 2)) * cropH + (imgHeight - cropY - cropH)) / imgHeight
            allItems.append(TextItem(
                text: text, cx: bb.origin.x + bb.width / 2,
                left: bb.origin.x, right: bb.origin.x + bb.width,
                absY: absY, h: bb.height
            ))
        }
    } catch {}
}

log("Total items: \(allItems.count), Image: \(Int(imgWidth))x\(Int(imgHeight))")

allItems.sort { a, b in
    if abs(a.absY - b.absY) > 0.002 { return a.absY < b.absY }
    return a.cx < b.cx
}

// ─── Step 2: Initial row grouping (generous tolerance) ───
let heights = allItems.map { $0.h }.sorted()
let medianH = heights.count > 0 ? heights[heights.count / 2] : 0.02
let rowTol = medianH * 2.0

log("Median height: \(String(format: "%.5f", medianH)), Row tolerance: \(String(format: "%.5f", rowTol))")

var rawRows: [[TextItem]] = []
var curRow: [TextItem] = []
var anchorY: CGFloat = -1

for item in allItems {
    if curRow.isEmpty {
        curRow = [item]
        anchorY = item.absY
    } else {
        let dist = abs(item.absY - anchorY)
        if dist < rowTol {
            curRow.append(item)
        } else {
            curRow.sort { $0.cx < $1.cx }
            rawRows.append(curRow)
            curRow = [item]
            anchorY = item.absY
        }
    }
}
if !curRow.isEmpty {
    curRow.sort { $0.cx < $1.cx }
    rawRows.append(curRow)
}

log("Initial groups: \(rawRows.count)")

// ─── Step 3: Column detection (before split, uses gap frequency) ───
// Use all items sorted by X within each group to find column gaps
let referenceRows = rawRows.sorted { $0.count > $1.count }.prefix(15)

var gapPositions: [CGFloat: Int] = [:]
for row in referenceRows {
    guard row.count >= 3 else { continue }
    for i in 1..<row.count {
        let gap = row[i].left - row[i-1].right
        if gap > 0.008 {
            let midPos = (row[i-1].right + row[i].left) / 2
            let bin = (midPos * 200).rounded() / 200
            gapPositions[bin, default: 0] += 1
        }
    }
}

var colBounds: [CGFloat] = [0.0]
let minCount = 3  // Gap must appear in at least 3 rows across references
let sortedGaps = gapPositions
    .filter { $0.value >= minCount }
    .sorted { $0.value > $1.value }

for (pos, count) in sortedGaps {
    if count >= 2 {
        log("  gap pos=\(String(format: "%.3f", pos)) count=\(count)")
    }
    let tooClose = colBounds.contains { abs($0 - pos) < 0.025 }
    if !tooClose {
        colBounds.append(pos)
    }
}
colBounds.sort()
colBounds.append(1.0)
let numCols = max(2, colBounds.count - 1)

log("Column bounds: \(colBounds.map { String(format: "%.3f", $0) })")
log("Detected \(numCols) columns")

// ─── Step 2b: Split over-merged rows using numCols ───
var splitRows: [[TextItem]] = []
for row in rawRows {
    guard row.count > numCols + 2 else {
        splitRows.append(row)
        continue
    }
    let byY = row.sorted { $0.absY < $1.absY }
    let yGaps: [(idx: Int, gap: CGFloat)] = (1..<byY.count).map { i in
        (i, byY[i].absY - byY[i-1].absY)
    }
    let expectedLines = max(1, Int(ceil(Double(row.count) / Double(max(numCols, 2)))))
    if expectedLines <= 1 {
        splitRows.append(row)
        continue
    }
    // Take top (expectedLines - 1) gaps as split points
    let splitPoints = yGaps.sorted { $0.gap > $1.gap }.prefix(expectedLines - 1).map { $0.idx }.sorted()
    var start = 0
    for sp in splitPoints {
        let subLine = Array(byY[start..<sp]).sorted { $0.cx < $1.cx }
        if !subLine.isEmpty { splitRows.append(subLine) }
        start = sp
    }
    let lastLine = Array(byY[start...]).sorted { $0.cx < $1.cx }
    if !lastLine.isEmpty { splitRows.append(lastLine) }
}
rawRows = splitRows

log("After split: \(rawRows.count) rows")

// ─── Step 3b: Validate column boundaries ───
// Remove boundaries that create mostly-empty columns
var validBounds = colBounds
var nc = validBounds.count - 1
if nc > 2 {
    // Quick test: count non-empty cells per column
    var colFill = Array(repeating: 0, count: nc)
    let sampleRows = rawRows.prefix(30)
    for row in sampleRows {
        var cells = Array(repeating: false, count: nc)
        for item in row {
            var col = nc - 1
            for c in 0..<nc {
                if item.cx < validBounds[c + 1] { col = c; break }
            }
            cells[col] = true
        }
        for c in 0..<nc { if cells[c] { colFill[c] += 1 } }
    }
    let threshold = max(2, sampleRows.count / 5)  // column must have content in >20% of rows
    // Remove boundaries that create empty columns (check from right to left)
    for c in (1..<nc-1).reversed() {  // skip first and last columns
        if colFill[c] < threshold {
            log("  Removing boundary at \(String(format: "%.3f", validBounds[c])) — column \(c) only filled in \(colFill[c])/sampleRows.count rows")
            validBounds.remove(at: c)
        }
    }
    nc = validBounds.count - 1
}
colBounds = validBounds
let finalNumCols = max(2, nc)

log("Validated column bounds: \(colBounds.map { String(format: "%.3f", $0) })")
log("Final \(finalNumCols) columns")

// ─── Step 4: Assign items to columns, merge continuation rows ───
struct TableRow { var cells: [String] }
var tableRows: [TableRow] = []

for row in rawRows {
    var cells = Array(repeating: [String](), count: finalNumCols)

    for item in row {
        var col = finalNumCols - 1
        for c in 0..<finalNumCols {
            if item.cx < colBounds[c + 1] {
                col = c
                break
            }
        }
        cells[col].append(item.text)
    }

    let cellStrings = cells.map { $0.joined(separator: "\n") }
    let hasContent = cellStrings.contains { !$0.isEmpty }

    // Continuation row: first column (ID/序号) is empty → merge into previous row
    let isContinuation = !cellStrings.isEmpty && cellStrings[0].isEmpty && hasContent

    if isContinuation && !tableRows.isEmpty {
        let prevIdx = tableRows.count - 1
        for c in 0..<finalNumCols {
            if !cellStrings[c].isEmpty {
                if !tableRows[prevIdx].cells[c].isEmpty {
                    tableRows[prevIdx].cells[c] += "\n" + cellStrings[c]
                } else {
                    tableRows[prevIdx].cells[c] = cellStrings[c]
                }
            }
        }
    } else if hasContent {
        tableRows.append(TableRow(cells: cellStrings))
    }
}

log("Final table rows: \(tableRows.count)")

// ─── Step 5: Output ───
for row in tableRows {
    let escaped = row.cells.map { $0.replacingOccurrences(of: "\n", with: "\\n") }
    print(escaped.joined(separator: "\t"))
}
