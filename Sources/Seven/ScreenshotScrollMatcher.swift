import CoreGraphics
import Foundation
import ScrollRegistrationCore

/// Screenshot-specific RGBA/grayscale frame; pixels are used only for in-memory stitching and never written to diagnostics.
struct ScreenshotScrollFrame {
    let image: CGImage
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let gray: [UInt8]

    init(image: CGImage) throws {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: .init(alpha: .premultipliedLast, byteOrder: .order32Big)) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ScreenshotTranslationError.captureFailed }
        self.image = image; self.width = width; self.height = height; self.pixels = pixels
        var grayscale = [UInt8]()
        grayscale.reserveCapacity(width * height)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[offset]) * 0.299
            let green = Double(pixels[offset + 1]) * 0.587
            let blue = Double(pixels[offset + 2]) * 0.114
            grayscale.append(UInt8((red + green + blue).rounded()))
        }
        gray = grayscale
    }


}

enum ScreenshotScrollSample: Equatable {
    case unchanged, movedWithinRange, noMatch, limitReached
    case addedPixels(Int)
}

/// Diagnostics pass only numbers, fixed categories, and relative coordinates; never screenshot pixels or page text.
struct ScreenshotScrollMatchInfo: Codable, Sendable {
    enum Reason: String, Codable { case initial, identical, sizeChanged, noFeatures, noCandidate, overlapRejected, withinRange, extendedTop, extendedBottom, pixelLimit, allocationFailed }
    enum Reference: String, Codable { case previousFrame, collectedImage, collectedViewport }
    struct Stage: Codable, Sendable {
        let width: Int
        let candidates: Int
        let survivors: Int
        let displacement: Int
        let bestMismatch: Double?
        let cutoffMismatch: Double?
    }
    var stageHistory: [Stage]?
    var stages: Int?
    var validPixels: Int?
    var badPixels: Int?
    var roiWidth: Int?
    var roiHeight: Int?
    var reason: Reason = .initial
    var reference: Reference = .previousFrame
    var referencePosition: Int?
    var directionHint = 0
    var displacement: Int?
    var featureRows = 0
    var candidates = 0
    var bestMismatch: Double?
    var overlap = 0
    var position = 0
    var lower = 0
    var upper = 0
}

/// Matches scroll frames via changed regions, mask scoring, and staged pruning, then stitches new frames onto existing strips.
/// Raw screenshot pixels are kept in memory only.
struct ScreenshotScrollMatcher {
    private struct Tile {
        let origin: Int
        let image: CGImage
        var end: Int { origin+image.height }
    }
    private let initial: ScreenshotScrollFrame
    private var current: ScreenshotScrollFrame
    private var tiles: [Tile]
    private var references: ScreenshotScrollReferences
    var referenceCount: Int { references.count }
    private let maximumPixels: Int
    private(set) var position = 0
    private(set) var lower = 0, upper = 0
    private(set) var acceptedFrames = 1
    private(set) var matchInfo = ScreenshotScrollMatchInfo()
    var addedHeight: Int { upper-lower }
    var outputHeight: Int { initial.height+addedHeight }

    init(initial:ScreenshotScrollFrame,maximumPixels:Int = ScreenshotScrollPolicy.maximumPixels) {
        self.initial=initial;current=initial;self.maximumPixels=maximumPixels
        tiles=[Tile(origin:0,image:initial.image)]
        references = ScreenshotScrollReferences(width: initial.width, height: initial.height)
        references.remember(initial, position: 0, lower: 0, upper: 0)
    }
    mutating func consume(_ frame:ScreenshotScrollFrame,directionHint:Int = 0)->ScreenshotScrollSample {
        matchInfo = .init(directionHint:directionHint,position:position,lower:lower,upper:upper)
        guard frame.width==initial.width,frame.height==initial.height else {matchInfo.reason = .sizeChanged;return .noMatch}
        if frame.pixels==current.pixels {matchInfo.reason = .identical;matchInfo.displacement=0;return .unchanged}
        var found=current.gray.withUnsafeBufferPointer { old in
            frame.gray.withUnsafeBufferPointer { next in seven_scroll_match(old.baseAddress,next.baseAddress,Int32(frame.width),Int32(frame.height)) }
        }
        var referencePosition = position
        // Repeating rows can give the previous frame a plausible but wrong offset; also compare against historical viewports,
        // preferring exact revisits or lower-error captured positions rather than recovering only after the previous frame fails outright.
        if found.status != 0, found.score > 0,
           let relocated = references.locate(frame),
           found.status != 1 || relocated.match.status == 0 || relocated.match.score < found.score {
            found = relocated.match
            referencePosition = relocated.position + Int(found.offset)
            matchInfo.reference = .collectedViewport
            matchInfo.referencePosition = referencePosition
        }
        var history=found.history
        matchInfo.stageHistory=withUnsafeBytes(of:&history) { storage in
            storage.bindMemory(to:SevenScrollStage.self).prefix(Int(found.stages)).map { stage in
                .init(width:Int(stage.width),candidates:Int(stage.candidates),survivors:Int(stage.survivors),displacement:-Int(stage.best_offset),
                      bestMismatch:stage.best_score<Float.greatestFiniteMagnitude ? Double(stage.best_score):nil,
                      cutoffMismatch:stage.cutoff_score<Float.greatestFiniteMagnitude ? Double(stage.cutoff_score):nil)
            }
        }
        matchInfo.candidates=Int(found.candidates);matchInfo.stages=Int(found.stages)
        matchInfo.validPixels=Int(found.valid_pixels);matchInfo.badPixels=Int(found.bad_pixels)
        matchInfo.roiWidth=Int(found.roi_width);matchInfo.roiHeight=Int(found.roi_height)
        matchInfo.overlap=max(0,Int(found.roi_height)-abs(Int(found.offset)))
        if found.score.isFinite,found.score<Float.greatestFiniteMagnitude {matchInfo.bestMismatch=Double(found.score)}
        // The kernel compares A[y] with B[y+d], so the logical viewport delta is negated. Record rejected candidates too without mixing error/overlap from another reference.
        let next = referencePosition - Int(found.offset)
        let movement = next - position
        matchInfo.displacement = -Int(found.offset)
        if found.status==0 && matchInfo.reference == .previousFrame {
            current=frame;matchInfo.reason = .withinRange
            return .unchanged
        }
        guard found.status == 1 || (found.status == 0 && matchInfo.reference == .collectedViewport) else {
            matchInfo.reason = found.status==3 ? .allocationFailed : found.valid_pixels==0 ? .noFeatures : .overlapRejected
            return .noMatch
        }
        let newLower=min(lower,next),newUpper=max(upper,next)
        let added=newUpper-newLower-addedHeight
        guard frame.height+newUpper-newLower<=maximumPixels/max(1,frame.width) else {matchInfo.reason = .pixelLimit;return .limitReached}
        if added>0 {
            let half=frame.height/2
            let sourceTop=next<lower ? 0 : half
            let count=next<lower ? half : frame.height-half
            let origin=next+sourceTop
            guard origin<=upper+frame.height,origin+count>=lower,
                  let image=compact(frame.image,top:sourceTop,count:count),
                  let updated=contact(Tile(origin:origin,image:image)) else {matchInfo.reason = .allocationFailed;return .noMatch}
            tiles=updated
        }
        current=frame;position=next;lower=newLower;upper=newUpper
        references.remember(frame, position: position, lower: lower, upper: upper)
        matchInfo.position=position;matchInfo.lower=lower;matchInfo.upper=upper
        matchInfo.reason=added>0 ? (movement<0 ? .extendedTop:.extendedBottom):.withinRange
        if movement != 0 {acceptedFrames+=1}
        return added>0 ? .addedPixels(added):.movedWithinRange
    }
    /// Overwrites matching logical row ranges segment by segment while preserving uncovered flanks; never fabricates gaps.
    private func contact(_ incoming:Tile)->[Tile]? {
        var result:[Tile]=[]
        for tile in tiles {
            if tile.end<=incoming.origin || tile.origin>=incoming.end {result.append(tile);continue}
            if tile.origin<incoming.origin {
                guard let image=compact(tile.image,top:0,count:incoming.origin-tile.origin) else {return nil}
                result.append(Tile(origin:tile.origin,image:image))
            }
            if tile.end>incoming.end {
                guard let image=compact(tile.image,top:incoming.end-tile.origin,count:tile.end-incoming.end) else {return nil}
                result.append(Tile(origin:incoming.end,image:image))
            }
        }
        result.append(incoming);result.sort {$0.origin<$1.origin}
        for i in result.indices.dropFirst() where result[i-1].end != result[i].origin {return nil}
        return result
    }
    private func compact(_ image:CGImage,top:Int,count:Int)->CGImage? {
        guard count>0,top>=0,top+count<=image.height,
              let crop=image.cropping(to:CGRect(x:0,y:top,width:image.width,height:count)),
              let context=CGContext(data:nil,width:image.width,height:count,bitsPerComponent:8,bytesPerRow:image.width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo: .init(alpha: .premultipliedLast)) else {return nil}
        context.draw(crop,in:CGRect(x:0,y:0,width:image.width,height:count));return context.makeImage()
    }
    var image:CGImage? {render(maximumSize:nil)}
    func previewImage(maximumSize:CGSize)->CGImage? {render(maximumSize:maximumSize)}
    private func render(maximumSize:CGSize?)->CGImage? {
        let height=outputHeight
        let factor=maximumSize.map {min(1,$0.width/CGFloat(initial.width),$0.height/CGFloat(height))} ?? 1
        let width=max(1,Int(CGFloat(initial.width)*factor)),targetHeight=max(1,Int(CGFloat(height)*factor))
        guard let context=CGContext(data:nil,width:width,height:targetHeight,bitsPerComponent:8,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo: .init(alpha: .premultipliedLast)) else {return nil}
        if maximumSize != nil {context.interpolationQuality = .high}
        context.scaleBy(x:CGFloat(width)/CGFloat(initial.width),y:CGFloat(targetHeight)/CGFloat(height))
        for tile in tiles {
            let y=tile.origin-lower
            context.draw(tile.image,in:CGRect(x:0,y:height-y-tile.image.height,width:initial.width,height:tile.image.height))
        }
        return context.makeImage()
    }
}

/// Sampling cadence and image budgets are capture policy, not visual styling.
enum ScreenshotScrollPolicy {
    static let sampleInterval:TimeInterval=0.10
    /// Cadence is timed from sample start; after 108ms of processing, capture the latest frame immediately instead of waiting for the next 200ms tick.
    static func delayUntilNextSample(elapsed:TimeInterval)->TimeInterval { max(0,sampleInterval-elapsed) }
    static let activityTimeout:TimeInterval=3
    static let failureNoticeDelay:TimeInterval=3 // After continuous match failures reach this duration, show the inline recovery prompt.
    static let maximumPixels=80_000_000
}
