import AppKit
import XCTest
@testable import Seven

final class ScreenshotScrollTraceTests: XCTestCase {
    func testDefaultOffThenWritesOnlyTypedMetadataWithPrivatePermissions() async throws {
        let suite = "ScrollTrace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite,isDirectory:true)
        defer { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:directory) }
        XCTAssertNil(ScreenshotScrollTrace.start(defaults:defaults,directory:directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
        defaults.set(true,forKey:ScreenshotScrollTrace.enabledKey)
        let trace = try XCTUnwrap(ScreenshotScrollTrace.start(defaults:defaults,directory:directory))
        let token = UUID()
        let match = ScreenshotScrollMatchInfo(reason:.extendedTop,directionHint:-1,displacement:-40,candidates:3,bestMismatch:0,overlap:80,position:-40,lower:-40,upper:100)
        trace.record(.sampleFinished,sequence:1,generation:token,rect:CGRect(x:-100,y:50,width:400,height:300),pixelWidth:800,pixelHeight:600,scale:2,wheelDeltaY:5,elapsedMS:12,match:match)
        await trace.flushed()
        let entries = try String(contentsOf:trace.fileURL,encoding:.utf8).split(separator:"\n")
        XCTAssertEqual(entries.count,1)
        let entry = try JSONDecoder().decode(ScreenshotScrollTrace.Entry.self,from:Data(entries[0].utf8))
        XCTAssertEqual(entry.match?.displacement,-40);XCTAssertEqual(entry.generation,token)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(entries[0].utf8)) as? [String:Any])
        let allowed: Set<String> = ["time","kind","sequence","generation","rect","pixelWidth","pixelHeight","scale","wheelDeltaY","elapsedMS","match"]
        XCTAssertTrue(Set(json.keys).isSubset(of:allowed), "日志结构不接受页面正文、图片或任意错误信息")
        let matchFields = try XCTUnwrap(json["match"] as? [String: Any])
        XCTAssertNil(matchFields["engine"])
        var previousMatch = matchFields
        previousMatch["engine"] = "legacy"
        var previousJSON = json
        previousJSON["match"] = previousMatch
        let previousData = try JSONSerialization.data(withJSONObject: previousJSON)
        let previousEntry = try JSONDecoder().decode(ScreenshotScrollTrace.Entry.self, from: previousData)
        XCTAssertEqual(previousEntry.match?.displacement, -40)
        let folderMode = try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath:trace.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(folderMode?.intValue,0o700);XCTAssertEqual(fileMode?.intValue,0o600)
    }

    @MainActor func testCaptureResetAndCancellationAreCorrelatedWithoutLateSuccess() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScrollTrace-\(UUID().uuidString)",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let trace = try ScreenshotScrollTrace(directory:directory)
        let context = try XCTUnwrap(CGContext(data:nil,width:100,height:80,bitsPerComponent:8,bytesPerRow:400,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let controller = ScreenshotScrollWindowController(rect:CGRect(x:0,y:0,width:100,height:80),capture:{_,_ in image},diagnostics:trace,completed:{_ in XCTFail("取消不应交付图片")})
        controller.sample();await controller.sampling?.value
        controller.resetCapture()
        let pending = controller.sampling
        controller.close();await pending?.value
        await trace.flushed()
        let entries = try String(contentsOf:trace.fileURL,encoding:.utf8).split(separator:"\n").map { try JSONDecoder().decode(ScreenshotScrollTrace.Entry.self,from:Data($0.utf8)) }
        XCTAssertEqual(entries.first?.kind,.started)
        XCTAssertTrue(entries.contains { $0.kind == .reset })
        XCTAssertTrue(entries.contains { $0.kind == .cancelled })
        XCTAssertTrue(entries.contains { $0.kind == .discarded })
        XCTAssertEqual(entries.filter { $0.kind == .sampleFinished }.count,1)
        XCTAssertFalse(entries.contains { $0.kind == .finished })
    }
    @MainActor func testSuccessfulFinishFlushesDiagnosticAndDoesNotReportCancellation() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScrollTrace-\(UUID().uuidString)",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let trace = try ScreenshotScrollTrace(directory:directory)
        let context = try XCTUnwrap(CGContext(data:nil,width:100,height:80,bitsPerComponent:8,bytesPerRow:400,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let done = expectation(description:"已完成")
        let controller = ScreenshotScrollWindowController(rect:CGRect(x:0,y:0,width:100,height:80),capture:{_,_ in image},diagnostics:trace,completed:{_ in done.fulfill()})
        defer {controller.close()}
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("editImage"),to:controller,from:nil))
        await fulfillment(of:[done],timeout:2)
        await trace.flushed()
        let entries = try String(contentsOf:trace.fileURL,encoding:.utf8).split(separator:"\n").map {try JSONDecoder().decode(ScreenshotScrollTrace.Entry.self,from:Data($0.utf8))}
        XCTAssertEqual(entries.last?.kind,.finished)
        XCTAssertFalse(entries.contains {$0.kind == .cancelled})
        XCTAssertEqual(entries.filter {$0.kind == .sampleFinished}.count,1)
    }
}
