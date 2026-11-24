import XCTest
import ScrollRegistrationCore
@testable import Seven

final class ScreenshotScrollRegistrationTests: XCTestCase {
    private func pixels(width:Int,height:Int,offset:Int = 0)->[UInt8] {
        (0..<height).flatMap { y in
            (0..<width).map { x in
                var value=UInt32(truncatingIfNeeded:(y+offset)&*7907 &+ x&*104729)
                value ^= value>>16;value &*= 0x45d9f3b;value ^= value>>16
                return UInt8(truncatingIfNeeded:value)
            }
        }
    }
    private func match(_ a:[UInt8],_ b:[UInt8],width:Int,height:Int)->SevenScrollMatch {
        a.withUnsafeBufferPointer { old in b.withUnsafeBufferPointer { next in seven_scroll_match(old.baseAddress,next.baseAddress,Int32(width),Int32(height)) } }
    }
    func testMaskedPixelScoringAcceptsSmallDynamicPatchAndRetainsVerticalPrecision() {
        let width=128,height=100
        let a=pixels(width:width,height:height)
        var b=pixels(width:width,height:height,offset:13)
        for y in 30..<40 {for x in 20..<35 {b[y*width+x]=255-b[y*width+x]}}
        let result=match(a,b,width:width,height:height)
        XCTAssertEqual(result.status,1);XCTAssertEqual(result.offset,-13)
        XCTAssertGreaterThan(result.bad_pixels,0);XCTAssertGreaterThan(result.valid_pixels,result.bad_pixels)
        XCTAssertEqual(result.score,Float(result.bad_pixels)/Float(result.valid_pixels),accuracy:0.00001)
        XCTAssertLessThan(result.score,0.3)
        XCTAssertEqual(result.stages,6, "128/32=4，4/8/16/32/64/128逐级评分")
    }
    func testAreaReductionTo512KeepsOnePixelVerticalMotion() {
        let width=1024,height=100
        let base=pixels(width:512,height:height),next=pixels(width:512,height:height,offset:1)
        let a=base.flatMap {[$0,$0]},b=next.flatMap {[$0,$0]}
        let result=match(a,b,width:width,height:height)
        XCTAssertEqual(result.status,1);XCTAssertEqual(result.offset,-1)
        XCTAssertEqual(result.roi_width,512);XCTAssertEqual(result.roi_height,100)
        XCTAssertEqual(result.score,0)
    }
    func testLocalBlinkReturnsZeroWithoutInterpretingItAsScroll() {
        let width=128,height=100
        let a=pixels(width:width,height:height)
        var b=a
        for y in 35..<45 {for x in 20..<30 {b[y*width+x]=255-b[y*width+x]}}
        let result=match(a,b,width:width,height:height)
        XCTAssertEqual(result.status,0);XCTAssertEqual(result.offset,0)
        XCTAssertLessThan(Int(result.roi_width)*Int(result.roi_height),width*height*3/10)
        XCTAssertEqual(result.stages,0)
    }
    func testUnrelatedImageIsRejectedWithSingleConsistentCandidateStatistics() {
        let width=128,height=100
        let a=pixels(width:width,height:height),b=pixels(width:width,height:height,offset:500)
        let result=match(a,b,width:width,height:height)
        XCTAssertEqual(result.status,2)
        XCTAssertGreaterThanOrEqual(result.score,0.3)
        XCTAssertEqual(result.score,Float(result.bad_pixels)/Float(result.valid_pixels),accuracy:0.00001)
    }
    func testActualShiftBeyondHalfRoiCannotBeInventedAsValidOverlap() {
        let width=128,height=100
        let result=match(pixels(width:width,height:height),pixels(width:width,height:height,offset:60),width:width,height:height)
        XCTAssertEqual(result.status,2)
    }
    func testStageDiagnosticsDescribeTheActualPruningSequence() {
        let width=128,height=100
        var result=match(pixels(width:width,height:height),pixels(width:width,height:height,offset:13),width:width,height:height)
        let history=withUnsafeBytes(of:&result.history) {Array($0.bindMemory(to:SevenScrollStage.self).prefix(Int(result.stages)))}
        XCTAssertEqual(history.map {Int($0.width)},[4,8,16,32,64,128])
        for (index,stage) in history.enumerated() {
            XCTAssertEqual(stage.survivors,max(1,stage.candidates/2))
            XCTAssertLessThanOrEqual(stage.best_score,stage.cutoff_score)
            if index>0 {XCTAssertEqual(stage.candidates,history[index-1].survivors)}
        }
        XCTAssertEqual(history.last?.best_offset,result.offset)
        XCTAssertEqual(history.last?.best_score,result.score)
    }
}
