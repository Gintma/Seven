import AppKit
import UniformTypeIdentifiers

enum ScreenshotSaveLocation: String, CaseIterable, Identifiable {
    case ask, desktop, folder
    var id: Self {self}
    var title:String {switch self {case .ask:return L10n.text("askEveryTime");case .desktop:return L10n.text("desktop");case .folder:return L10n.text("specifiedFolder")}}
}
enum ScreenshotSaveFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id:Self {self}
    var title:String {self == .png ? "PNG":"JPG (JPEG)"}
    var fileExtension:String {self == .png ? "png":"jpg"}
    var type:UTType {self == .png ? .png:.jpeg}
}
final class ScreenshotSavePreferences {
    static let locationKey="screenshotSave.location.v1",folderKey="screenshotSave.folder.v1",formatKey="screenshotSave.format.v1"
    private let defaults:UserDefaults?
    init(defaults:UserDefaults? = nil){self.defaults=defaults}
    var location:ScreenshotSaveLocation {defaults?.string(forKey:Self.locationKey).flatMap(ScreenshotSaveLocation.init(rawValue:)) ?? .ask}
    var format:ScreenshotSaveFormat {defaults?.string(forKey:Self.formatKey).flatMap(ScreenshotSaveFormat.init(rawValue:)) ?? .png}
    var folder:URL? {defaults?.string(forKey:Self.folderKey).map {URL(filePath: $0, directoryHint: .isDirectory)}}
    var directory:URL? {switch location {case .ask:return nil;case .desktop:return FileManager.default.urls(for:.desktopDirectory,in:.userDomainMask).first;case .folder:return folder}}
}

@MainActor enum ScreenshotSaving {
    static func filename(date:Date=Date(),format:ScreenshotSaveFormat,timeZone:TimeZone = .current)->String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.calendar=Calendar(identifier:.gregorian)
        formatter.timeZone=timeZone;formatter.dateFormat="yyyy-MM-dd_HH-mm-ss"
        return "Seven_\(formatter.string(from:date)).\(format.fileExtension)"
    }
    static func cgImage(_ image: NSImage) -> CGImage? {
        cgImage(image, from: largestPixelRepresentation(of: image))
    }

    static func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
        let representation = largestPixelRepresentation(of: image)
        if let bitmap = representation as? NSBitmapImageRep { return bitmap }
        guard let raster = cgImage(image, from: representation) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: raster)
        let size = image.size
        if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
            bitmap.size = size
        }
        return bitmap
    }

    private static func largestPixelRepresentation(of image: NSImage) -> NSImageRep? {
        image.representations.filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }.max {
            Double($0.pixelsWide) * Double($0.pixelsHigh) < Double($1.pixelsWide) * Double($1.pixelsHigh)
        }
    }

    private static func cgImage(_ image: NSImage, from representation: NSImageRep?) -> CGImage? {
        guard let representation else {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        if let bitmap = representation as? NSBitmapImageRep { return bitmap.cgImage }
        return representation.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    static func data(_ image:NSImage,format:ScreenshotSaveFormat)->Data? {
        let bitmap=bitmap(image)
        guard let bitmap else{return nil}
        if format == .png {return bitmap.representation(using:.png,properties:[:])}
        guard let source=bitmap.cgImage,
              let context=CGContext(data:nil,width:source.width,height:source.height,bitsPerComponent:8,bytesPerRow:source.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo: .init(alpha: .noneSkipLast)) else{return nil}
        context.setFillColor(Design.ScreenshotSave.jpegBackground.cgColor);context.fill(CGRect(x:0,y:0,width:source.width,height:source.height))
        context.draw(source,in:CGRect(x:0,y:0,width:source.width,height:source.height))
        guard let flattened=context.makeImage() else{return nil}
        return NSBitmapImageRep(cgImage:flattened).representation(using:.jpeg,properties:[.compressionFactor:0.9])
    }
    static func makePanel(parent:NSWindow?,format:ScreenshotSaveFormat)->NSSavePanel {
        let panel=NSSavePanel();panel.nameFieldStringValue=filename(format:format);panel.allowedContentTypes=[format.type]
        panel.level=NSWindow.Level(rawValue:(parent?.level.rawValue ?? 0)+2);return panel
    }
    static func writeUnique(_ data:Data,directory:URL,name:String)throws->URL {
        let base=directory.appending(path: name, directoryHint: .checkFileSystem),ext=base.pathExtension,stem=base.deletingPathExtension().lastPathComponent
        var suffix=0
        while true {
            let url=suffix==0 ? base:directory.appending(path: "\(stem)_\(suffix).\(ext)", directoryHint: .checkFileSystem)
            do {try data.write(to:url,options:.withoutOverwriting);return url}
            catch let error as CocoaError where error.code == .fileWriteFileExists {suffix+=1}
        }
    }
    static func save(_ image:NSImage,parent:NSWindow?,preferences:ScreenshotSavePreferences,completed:@escaping()->Void) {
        let format=preferences.format
        guard let data=data(image,format:format) else{return}
        func failure() {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L10n.text("screenshotSaveFailed")
            alert.informativeText = L10n.text("checkSavePermissionsAndFreeSpace")
            alert.addButton(withTitle: L10n.text("ok"))
            alert.window.level = NSWindow.Level(rawValue: (parent?.level.rawValue ?? 0) + 2)
            AppAlert.runModal(alert)
        }
        if let directory=preferences.directory {
            do {_ = try writeUnique(data,directory:directory,name:filename(format:format));completed()}catch{failure()}
            return
        }
        let panel=makePanel(parent:parent,format:format)
        let finish:(NSApplication.ModalResponse)->Void={result in
            guard result == .OK,let url=panel.url else{return}
            do {try data.write(to:url,options:.atomic);completed()}catch{failure()}
        }
        if let parent {panel.beginSheetModal(for:parent,completionHandler:finish)}else{panel.begin(completionHandler:finish)}
    }
}
