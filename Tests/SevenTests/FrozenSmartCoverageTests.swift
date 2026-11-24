import AppKit
import XCTest
@testable import Seven

private final class CoverageTree:FrozenSmartTreeReading {
    struct Item {var role:String;var frame:CGRect;var children:[Int]=[]}
    var items:[Int:Item]
    var hitNode:Int?
    var roots=[1]
    private(set) var reads=0
    init(_ items:[Int:Item],hit:Int?=nil) {self.items=items;hitNode=hit}
    func windows()->[Int] {roots}
    func hit(at point:CGPoint)->Int? {hitNode}
    func role(_ node:Int)->String? {reads+=1;return items[node]?.role}
    func frame(_ node:Int)->CGRect? {items[node]?.frame}
    func children(_ node:Int)->[Int] {items[node]?.children ?? []}
    func parent(_ node:Int)->Int? {items.first{$0.value.children.contains(node)}?.key}
}

final class FrozenSmartCoverageTests:XCTestCase {
    private let window=CGRect(x:0,y:0,width:1000,height:800)
    private let text=CGRect(x:200,y:300,width:240,height:24)
    private func selection(_ reader:CoverageTree,at point:CGPoint)->(FrozenSmartSelectionResult,CGRect?) {
        let result=FrozenSmartTree(reader:reader).query(at:point,in:window)
        return (result,FrozenSmartRegion.selection(at:point,in:window,ancestry:result.ancestry))
    }
    func testStandaloneTextAcrossRoleAndWrapperVariants() {
        for role in ["AXStaticText","AXParagraph","AXHeading","AXListItem","AXBlockQuote","AXCode"] {
            for depth in [0,1,8,24] {
                var nodes:[Int:CoverageTree.Item]=[1:.init(role:"AXWindow",frame:window,children:[2])]
                for id in 2..<(2+depth) {nodes[id] = .init(role:"AXGroup",frame:text,children:[id+1])}
                nodes[2+depth] = .init(role:role,frame:text)
                for hit in [1,2+depth] {
                    let reader=CoverageTree(nodes,hit:hit),point=CGPoint(x:230,y:312)
                    let (result,selected)=selection(reader,at:point)
                    XCTAssertEqual(selected,text,"\(role) depth=\(depth) hit=\(hit)")
                    let candidates=FrozenSmartRegion.candidates(at:point,in:window,ancestry:result.ancestry)
                    XCTAssertEqual(candidates.filter{$0.frame==text}.count,1,"同框包装不应产生重复层级")
                }
            }
        }
    }
    func testLabelBelongsToControlRowOrCellWhileIndependentTextDoesNot() {
        for role in Array(FrozenSmartRegion.controls)+["AXRow","AXCell"] {
            let owner=text.insetBy(dx:-12,dy:-8)
            let reader=CoverageTree([1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:role,frame:owner,children:[3]),3:.init(role:"AXStaticText",frame:text)],hit:3)
            let point=CGPoint(x:230,y:312),result=selection(reader,at:point)
            XCTAssertEqual(result.1,owner,role)
            XCTAssertFalse(FrozenSmartRegion.candidates(at:point,in:window,ancestry:result.0.ancestry).contains{$0.role=="AXStaticText"},role)
        }
    }
    func testPureTextBubbleIsSelectableAtContentAndPaddingAtAnyHeight() {
        for height:CGFloat in [16,40,80,180] {
            let content=CGRect(x:200,y:300,width:240,height:height),bubble=content.insetBy(dx:-12,dy:-8)
            let reader=CoverageTree([1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:"AXGroup",frame:bubble,children:[3]),3:.init(role:"AXStaticText",frame:content)],hit:3)
            for point in [CGPoint(x:230,y:content.midY),CGPoint(x:bubble.minX+2,y:bubble.midY)] {
                let (result,selected)=selection(reader,at:point)
                XCTAssertEqual(selected,bubble,"height=\(height)")
                XCTAssertTrue(result.ancestry.contains{$0.frame==bubble && $0.isTextBlock})
            }
        }
    }
    func testBubbleKeepsPaddingThroughSameFrameSpanWrappers() {
        let bubble=text.insetBy(dx:-12,dy:-8)
        for depth in [1,3,8] {
            var items:[Int:CoverageTree.Item]=[1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:"AXGroup",frame:bubble,children:[3])]
            for id in 3..<(3+depth) {items[id] = .init(role:"AXGroup",frame:text,children:[id+1])}
            items[3+depth] = .init(role:"AXStaticText",frame:text)
            let reader=CoverageTree(items,hit:3+depth)
            XCTAssertEqual(selection(reader,at:CGPoint(x:230,y:312)).1,bubble,"depth=\(depth)")
        }
    }
    func testParagraphFragmentsBelongToTightParentButSeparatedParagraphsDoNotMerge() {
        let first=CGRect(x:200,y:300,width:150,height:24),second=CGRect(x:350,y:300,width:90,height:24)
        let paragraph=first.union(second).insetBy(dx:-4,dy:-4)
        let reader=CoverageTree([1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:"AXGroup",frame:paragraph,children:[3,4]),3:.init(role:"AXStaticText",frame:first),4:.init(role:"AXStaticText",frame:second)],hit:3)
        XCTAssertEqual(selection(reader,at:CGPoint(x:220,y:312)).1,paragraph)
        reader.items[4]?.frame=second.offsetBy(dx:0,dy:140)
        reader.items[2]?.frame=CGRect(x:196,y:296,width:250,height:180)
        XCTAssertEqual(selection(reader,at:CGPoint(x:220,y:312)).1,first)
    }
    func testOversizedTextWrapperDoesNotReplaceIndividualParagraph() {
        let reader=CoverageTree([1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:"AXGroup",frame:CGRect(x:100,y:100,width:800,height:600),children:[3]),3:.init(role:"AXStaticText",frame:text)],hit:3)
        XCTAssertEqual(selection(reader,at:CGPoint(x:230,y:312)).1,text)
    }
    func testSemanticParagraphPreservesInlineLinkAsSeparateInteractiveTarget() {
        let link=CGRect(x:280,y:300,width:60,height:24)
        let reader=CoverageTree([1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:"AXParagraph",frame:text,children:[3,4]),3:.init(role:"AXStaticText",frame:text),4:.init(role:"AXLink",frame:link)],hit:3)
        XCTAssertEqual(selection(reader,at:CGPoint(x:210,y:312)).1,text)
        XCTAssertEqual(selection(reader,at:CGPoint(x:300,y:312)).1,link)
    }
    func testImagesAreOwnedByButtonsButRemainALayerInContentCards() {
        let image=CGRect(x:230,y:310,width:120,height:100),card=CGRect(x:210,y:290,width:160,height:140)
        for role in ["AXButton","AXCell","AXGroup"] {
            let reader=CoverageTree([1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:role,frame:card,children:[3]),3:.init(role:"AXImage",frame:image)],hit:3)
            let point=CGPoint(x:250,y:330),(result,selected)=selection(reader,at:point)
            XCTAssertEqual(selected,role == "AXGroup" ? image:card)
            let values=FrozenSmartRegion.candidates(at:point,in:window,ancestry:result.ancestry)
            XCTAssertEqual(values.contains{$0.frame==image},role != "AXButton")
        }
    }
    func testExpandedContainerAndMenuRolesExposeIndependentChildren() {
        for role in ["AXMenu","AXMenuBar","AXGrid","AXBrowser","AXUnknown","AXWebArea","AXPopover"] {
            let control=CGRect(x:220,y:310,width:120,height:32)
            let reader=CoverageTree([1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:role,frame:text.insetBy(dx:-30,dy:-30),children:[3]),3:.init(role:"AXMenuItem",frame:control)],hit:1)
            XCTAssertEqual(selection(reader,at:CGPoint(x:240,y:320)).1,control,role)
        }
    }
    func testSiblingParagraphPrefetchSkipsInlineFragmentCountAndCachesNextBlock() {
        let one=text.insetBy(dx:-8,dy:-8),two=one.offsetBy(dx:0,dy:one.height)
        let reader=CoverageTree([
            1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:"AXGroup",frame:CGRect(x:100,y:100,width:800,height:600),children:[3,6]),
            3:.init(role:"AXGroup",frame:one,children:[4,5]),
            4:.init(role:"AXStaticText",frame:CGRect(x:200,y:300,width:120,height:24)),5:.init(role:"AXStaticText",frame:CGRect(x:320,y:300,width:120,height:24)),
            6:.init(role:"AXGroup",frame:two,children:[7]),7:.init(role:"AXStaticText",frame:text.offsetBy(dx:0,dy:one.height))
        ],hit:4)
        let point=CGPoint(x:220,y:310),(result,selected)=selection(reader,at:point)
        XCTAssertEqual(selected,one);XCTAssertTrue(result.siblings.contains{$0.frame==two && $0.isTextBlock})
        var cache=FrozenSmartSelectionCache();let candidate=FrozenWindowCandidate(id:1,frame:window,ownerPID:10)
        _ = cache.target(at:point,in:candidate,result:result)
        XCTAssertEqual(cache.element(at:CGPoint(x:220,y:two.midY),in:candidate)?.frame,two)
        let hierarchy=cache.hierarchy(at:point,in:candidate)
        XCTAssertTrue(hierarchy.enumerated().allSatisfy{index,region in !hierarchy.prefix(index).contains{$0.frame==region.frame}})
    }
    func testNestedSheetAndPopoverMatchTheirSurfaceAndNotTheParentWindow() {
        let surface=CGRect(x:120,y:160,width:500,height:360),control=CGRect(x:200,y:250,width:120,height:32)
        for role in ["AXSheet","AXDialog","AXSystemDialog","AXDrawer","AXPopover"] {
            let reader=CoverageTree([1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:role,frame:surface,children:[3]),3:.init(role:"AXButton",frame:control)],hit:3)
            let point=CGPoint(x:230,y:265),tree=FrozenSmartTree(reader:reader).query(at:point,in:surface)
            XCTAssertEqual(FrozenSmartRegion.selection(at:point,in:surface,ancestry:tree.ancestry),control,role)
            XCTAssertFalse(tree.ancestry.contains{$0.role=="AXWindow" && $0.frame==window})
        }
        let impostor=CoverageTree([1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:"AXButton",frame:surface)],hit:2)
        XCTAssertTrue(FrozenSmartTree(reader:impostor).query(at:CGPoint(x:230,y:265),in:surface).ancestry.isEmpty)
    }
    func testViewportClipsTextAndRejectsInvalidOrOffscreenCandidates() {
        let viewport=CGRect(x:190,y:305,width:260,height:100),point=CGPoint(x:220,y:312)
        let path=[FrozenSmartRegion(role:"AXStaticText",frame:text),.init(role:"AXScrollArea",frame:viewport),.init(role:"AXWindow",frame:window)]
        XCTAssertEqual(FrozenSmartRegion.selection(at:point,in:window,ancestry:path),text.intersection(viewport))
        for frame in [CGRect.null,.infinite,CGRect(x:20,y:20,width:0,height:40),CGRect(x:1200,y:200,width:100,height:40)] {
            var cache=FrozenSmartSelectionCache()
            let selected=cache.target(at:point,in:.init(id:1,frame:window),result:.init(ancestry:[.init(role:"AXStaticText",frame:frame)],siblings:[.init(role:"AXStaticText",frame:frame)]))
            XCTAssertNil(selected)
        }
    }
    func testTextOnlyCyclesAndHugeFragmentTreesStayBounded() {
        let reader=CoverageTree([1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:"AXGroup",frame:text.insetBy(dx:-4,dy:-4),children:[3]),3:.init(role:"AXGroup",frame:text,children:[2])],hit:nil)
        var checks=0
        _ = FrozenSmartTree(reader:reader).query(at:CGPoint(x:220,y:312),in:window,withinBudget:{checks+=1;return checks<300})
        XCTAssertLessThanOrEqual(reader.reads,3)
        var nodes:[Int:CoverageTree.Item]=[1:.init(role:"AXWindow",frame:window,children:[2]),2:.init(role:"AXGroup",frame:window.insetBy(dx:10,dy:10),children:Array(3...103))]
        for id in 3...103 {nodes[id] = .init(role:"AXStaticText",frame:text.offsetBy(dx:CGFloat(id-3)*2,dy:0))}
        reader.items=nodes
        checks=0
        _ = FrozenSmartTree(reader:reader).query(at:CGPoint(x:220,y:312),in:window,withinBudget:{checks+=1;return checks<300})
        XCTAssertLessThan(checks,310)
    }
}
