import AppKit

enum ScreenshotShadowKind {case screenshot,pin}
struct ScreenshotShadowStyle {
    var enabled:Bool
    var opacity:Double
    var rgb:Int
    var effective:Bool {enabled && opacity>0}
    var inset:CGFloat {effective ? Design.ScreenshotShadow.inset:0}
    var color:NSColor {Design.ScreenshotShadow.color(rgb:rgb,alpha:opacity)}
    var native:NSShadow? {
        guard effective else{return nil}
        let value=NSShadow();value.shadowColor=color;value.shadowBlurRadius=Design.ScreenshotShadow.blur;value.shadowOffset=Design.ScreenshotShadow.offset;return value
    }
}
final class ScreenshotShadowPreferences {
    static let captureEnabled="screenshotShadow.enabled.v1",captureOpacity="screenshotShadow.opacity.v1",captureColor="screenshotShadow.color.v1"
    static let pinEnabled="pinShadow.enabled.v1",pinOpacity="pinShadow.opacity.v1",pinColor="pinShadow.color.v1"
    private let defaults:UserDefaults?
    init(defaults:UserDefaults? = nil){self.defaults=defaults}
    func style(_ kind:ScreenshotShadowKind)->ScreenshotShadowStyle {
        let pin=kind == .pin
        return ScreenshotShadowStyle(enabled:defaults?.object(forKey:pin ? Self.pinEnabled:Self.captureEnabled) as? Bool ?? pin,
            opacity:min(1,max(0,defaults?.object(forKey:pin ? Self.pinOpacity:Self.captureOpacity) as? Double ?? Design.ScreenshotShadow.defaultOpacity)),
            rgb:Self.rgb(defaults?.string(forKey:pin ? Self.pinColor:Self.captureColor) ?? "000000"))
    }
    static func rgb(_ hex:String)->Int {Int(hex.trimmingCharacters(in:CharacterSet(charactersIn:"#")),radix:16) ?? 0}
    static func hex(_ color:NSColor)->String {
        guard let color=color.usingColorSpace(.sRGB) else{return "000000"}
        return String(format:"%02X%02X%02X",Int((min(1,max(0,color.redComponent))*255).rounded()),Int((min(1,max(0,color.greenComponent))*255).rounded()),Int((min(1,max(0,color.blueComponent))*255).rounded()))
    }
}

@MainActor enum ScreenshotShadowRendering {
    /// 阴影只画在圆角主体之外，不改变钉图主体的不透明度。
    static func draw(_ image:NSImage,in rect:CGRect,bounds:CGRect,radius:CGFloat,style:ScreenshotShadowStyle) {
        guard style.effective else{return}
        NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
        // 先按图片的 alpha 轮廓生成阴影，再移除主体；不能按矩形外沿裁切，
        // 否则圆角透明区内的阴影会被截掉，阴影看起来与图像脱离。
        let silhouette=NSImage(size:rect.size,flipped:false) { target in
            NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
            if radius>0 {NSBezierPath(roundedRect:target,xRadius:radius,yRadius:radius).addClip()}
            image.draw(in:target,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
            return true
        }
        guard let context=NSGraphicsContext.current?.cgContext else{return}
        context.beginTransparencyLayer(auxiliaryInfo:nil)
        style.native?.set()
        silhouette.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        context.setShadow(offset:.zero,blur:0,color:nil)
        silhouette.draw(in:rect,from:.zero,operation:.destinationOut,fraction:1,respectFlipped:true,hints:nil)
        context.endTransparencyLayer()
    }
    /// 导出只添加外围留白，原图像素保持不变；不用于钉图悬浮显示的复制/保存。
    static func image(_ source:NSImage,style:ScreenshotShadowStyle)->NSImage {
        guard style.effective,let original=ScreenshotSaving.cgImage(source),source.size.width>0,source.size.height>0 else{return source}
        let sx=CGFloat(original.width)/source.size.width,sy=CGFloat(original.height)/source.size.height
        let px=Int(ceil(style.inset*sx)),py=Int(ceil(style.inset*sy)),width=original.width+px*2,height=original.height+py*2
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo: .init(alpha: .premultipliedLast)) else{return source}
        let rect=CGRect(x:px,y:py,width:original.width,height:original.height)
        context.saveGState();context.setShadow(offset:CGSize(width:Design.ScreenshotShadow.offset.width*sx,height:Design.ScreenshotShadow.offset.height*sy),blur:Design.ScreenshotShadow.blur*max(sx,sy),color:style.color.cgColor)
        context.draw(original,in:rect);context.restoreGState()
        // 覆回主体，避免阴影使透明图像本身变暗。
        context.saveGState();context.clip(to:rect);context.setBlendMode(.copy);context.draw(original,in:rect);context.restoreGState()
        guard let output=context.makeImage() else{return source}
        let rep=NSBitmapImageRep(cgImage:output),size=CGSize(width:CGFloat(width)/sx,height:CGFloat(height)/sy)
        rep.size=size;let image=NSImage(size:size);image.addRepresentation(rep);return image
    }
}

/// 独立、穿透点击的阴影窗口只绘阴影，主体仍由原钉图窗口显示。
final class ScreenshotPinShadowView:NSView {
    var image:NSImage?
    var imageRect=CGRect.zero
    var radius:CGFloat=0
    var style=ScreenshotShadowStyle(enabled:false,opacity:0,rgb:0)
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func draw(_ dirtyRect:NSRect) {
        ThemePalette.clear.setFill();dirtyRect.fill(using:.copy)
        if let image {ScreenshotShadowRendering.draw(image,in:imageRect,bounds:bounds,radius:radius,style:style)}
    }
}
