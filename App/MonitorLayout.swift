import SwiftUI

/// Three stable children: video, compact navigation/status, primary actions.
/// Rotation/handedness changes placement only, never view identity or the decoder source.
struct MonitorLayout:Layout {
    let landscape:Bool
    let leftHanded:Bool
    let accessibility:Bool
    let gap:CGFloat=12
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        guard subviews.count == 3 else { return }
        let top=subviews[1].sizeThatFits(.init(width:bounds.width,height:nil)).height
        subviews[1].place(at:bounds.origin,anchor:.topLeading,proposal:.init(width:bounds.width,height:top))
        let body=CGRect(x:bounds.minX,y:bounds.minY+top+gap,width:bounds.width,height:max(0,bounds.height-top-gap))
        if landscape {
            let side=min(260,max(accessibility ? 200 : 176,bounds.width*0.28))
            let actionX=leftHanded ? body.minX : body.maxX-side
            let previewX=leftHanded ? body.minX+side+gap : body.minX
            subviews[0].place(at:.init(x:previewX,y:body.minY),anchor:.topLeading,
                proposal:.init(width:max(0,body.width-side-gap),height:body.height))
            subviews[2].place(at:.init(x:actionX,y:body.midY),anchor:.leading,
                proposal:.init(width:side,height:body.height))
        } else {
            let actions=subviews[2].sizeThatFits(.init(width:body.width,height:nil)).height
            subviews[0].place(at:body.origin,anchor:.topLeading,proposal:.init(width:body.width,height:max(0,body.height-actions-gap)))
            subviews[2].place(at:.init(x:body.minX,y:body.maxY-actions),anchor:.topLeading,proposal:.init(width:body.width,height:actions))
        }
    }
}
