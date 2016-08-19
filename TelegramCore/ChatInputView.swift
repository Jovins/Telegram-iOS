import Foundation
import UIKit
import Display
import AsyncDisplayKit
import WebKit

private let textInputViewBackground: UIImage = {
    let diameter: CGFloat = 10.0
    UIGraphicsBeginImageContextWithOptions(CGSize(width: diameter, height: diameter), true, 0.0)
    let context = UIGraphicsGetCurrentContext()!
    context.setFillColor(UIColor(0xfafafa).cgColor)
    context.fill(CGRect(x: 0.0, y: 0.0, width: diameter, height: diameter))
    context.setFillColor(UIColor.white.cgColor)
    context.fillEllipse(in: CGRect(x: 0.0, y: 0.0, width: diameter, height: diameter))
    context.setStrokeColor(UIColor(0xc7c7cc).cgColor)
    let strokeWidth: CGFloat = 0.5
    context.setLineWidth(strokeWidth)
    context.strokeEllipse(in: CGRect(x: strokeWidth / 2.0, y: strokeWidth / 2.0, width: diameter - strokeWidth, height: diameter - strokeWidth))
    let image = UIGraphicsGetImageFromCurrentImageContext()!.stretchableImage(withLeftCapWidth: Int(diameter / 2.0), topCapHeight: Int(diameter / 2.0))
    UIGraphicsEndImageContext()
    
    return image
}()

private let attachmentIcon = UIImage(bundleImageName: "Chat/Input/Text/IconAttachment")?.precomposed()

class ChatInputNode: ASDisplayNode, ASEditableTextNodeDelegate {
    var textPlaceholderNode: TextNode
    var textInputNode: ASEditableTextNode?
    
    let textInputBackgroundView: UIImageView
    let sendButton: UIButton
    let attachmentButton: UIButton
    
    var displayAttachmentMenu: () -> Void = { }
    var sendMessage: () -> Void = { }
    var updateHeight: () -> Void = { }
    
    var text: String {
        get {
            return self.textInputNode?.attributedText?.string ?? ""
        } set(value) {
            if let textInputNode = self.textInputNode {
                textInputNode.attributedText = NSAttributedString(string: value, font: Font.regular(16.0), textColor: UIColor.black)
                self.editableTextNodeDidUpdateText(textInputNode)
            }
        }
    }
    
    let textFieldInsets = UIEdgeInsets(top: 9.0, left: 41.0, bottom: 8.0, right: 0.0)
    let textInputViewInternalInsets = UIEdgeInsets(top: 4.0, left: 5.0, bottom: 4.0, right: 5.0)
    
    override init() {
        self.textInputBackgroundView = UIImageView(image: textInputViewBackground)
        self.textPlaceholderNode = TextNode()
        self.attachmentButton = UIButton()
        self.sendButton = UIButton()
        
        super.init()
        
        self.backgroundColor = UIColor(0xfafafa)
        
        self.attachmentButton.setImage(attachmentIcon, for: [])
        self.attachmentButton.addTarget(self, action: #selector(self.attachmentButtonPressed), for: .touchUpInside)
        self.view.addSubview(self.attachmentButton)
        
        self.sendButton.titleLabel?.font = Font.medium(17.0)
        self.sendButton.contentEdgeInsets = UIEdgeInsets(top: 8.0, left: 6.0, bottom: 8.0, right: 6.0)
        self.sendButton.setTitleColor(UIColor.blue, for: [])
        self.sendButton.setTitleColor(UIColor.gray, for: [.highlighted])
        self.sendButton.setTitle("Send", for: [])
        self.sendButton.sizeToFit()
        self.sendButton.addTarget(self, action: #selector(self.sendButtonPressed), for: .touchUpInside)
        
        self.view.addSubview(self.textInputBackgroundView)
        
        let placeholderLayout = TextNode.asyncLayout(self.textPlaceholderNode)
        let (placeholderSize, placeholderApply) = placeholderLayout(attributedString: NSAttributedString(string: "Message", font: Font.regular(16.0), textColor: UIColor(0xbebec0)), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: 320.0, height: CGFloat.greatestFiniteMagnitude), cutout: nil)
        self.textPlaceholderNode.frame = CGRect(origin: CGPoint(), size: placeholderSize.size)
        let _ = placeholderApply()
        self.addSubnode(self.textPlaceholderNode)
        
        self.view.addSubview(self.sendButton)
        
        self.textInputBackgroundView.clipsToBounds = true
        self.textInputBackgroundView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.textInputBackgroundViewTap(_:))))
        self.textInputBackgroundView.isUserInteractionEnabled = true
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func loadTextInputNode() {
        let textInputNode = ASEditableTextNode()
        textInputNode.typingAttributes = [NSFontAttributeName: Font.regular(16.0)]
        textInputNode.clipsToBounds = true
        textInputNode.delegate = self
        self.addSubnode(textInputNode)
        self.textInputNode = textInputNode
        
        let sendButtonSize = self.sendButton.bounds.size
        
        textInputNode.frame = CGRect(x: self.textFieldInsets.left + self.textInputViewInternalInsets.left, y: self.textFieldInsets.top + self.textInputViewInternalInsets.top, width: self.frame.size.width - self.textFieldInsets.left - self.textFieldInsets.right - sendButtonSize.width - self.textInputViewInternalInsets.left - self.textInputViewInternalInsets.right, height: self.frame.size.height - self.textFieldInsets.top - self.textFieldInsets.bottom - self.textInputViewInternalInsets.top - self.textInputViewInternalInsets.bottom)
        
        self.textInputBackgroundView.isUserInteractionEnabled = false
        self.textInputBackgroundView.removeGestureRecognizer(self.textInputBackgroundView.gestureRecognizers![0])
    }
    
    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        let sendButtonSize = self.sendButton.bounds.size
        let textFieldHeight: CGFloat
        if let textInputNode = self.textInputNode {
            textFieldHeight = min(115.0, max(20.0, ceil(textInputNode.measure(CGSize(width: constrainedSize.width - self.textFieldInsets.left - self.textFieldInsets.right - sendButtonSize.width - self.textInputViewInternalInsets.left - self.textInputViewInternalInsets.right, height: constrainedSize.height)).height)))
        } else {
            textFieldHeight = 20.0
        }
        
        return CGSize(width: constrainedSize.width, height: textFieldHeight + self.textFieldInsets.top + self.textFieldInsets.bottom + self.textInputViewInternalInsets.top + self.textInputViewInternalInsets.bottom)
    }
    
    override var frame: CGRect {
        get {
            return super.frame
        } set(value) {
            super.frame = value
            
            let sendButtonSize = self.sendButton.bounds.size
            let minimalHeight: CGFloat = 45.0
            self.sendButton.frame = CGRect(x: value.size.width - sendButtonSize.width, y: value.height - minimalHeight + floor((minimalHeight - sendButtonSize.height) / 2.0), width: sendButtonSize.width, height: sendButtonSize.height)
            
            self.attachmentButton.frame = CGRect(origin: CGPoint(x: 0.0, y: value.height - minimalHeight), size: CGSize(width: 40.0, height: minimalHeight))

            self.textInputNode?.frame = CGRect(x: self.textFieldInsets.left + self.textInputViewInternalInsets.left, y: self.textFieldInsets.top + self.textInputViewInternalInsets.top, width: value.size.width - self.textFieldInsets.left - self.textFieldInsets.right - sendButtonSize.width - self.textInputViewInternalInsets.left - self.textInputViewInternalInsets.right, height: value.size.height - self.textFieldInsets.top - self.textFieldInsets.bottom - self.textInputViewInternalInsets.top - self.textInputViewInternalInsets.bottom)
            
            self.textPlaceholderNode.frame = CGRect(origin: CGPoint(x: self.textFieldInsets.left + self.textInputViewInternalInsets.left, y: self.textFieldInsets.top + self.textInputViewInternalInsets.top + 0.5), size: self.textPlaceholderNode.frame.size)
            
            self.textInputBackgroundView.frame = CGRect(x: self.textFieldInsets.left, y: self.textFieldInsets.top, width: value.size.width -  self.textFieldInsets.left - self.textFieldInsets.right - sendButtonSize.width, height: value.size.height - self.textFieldInsets.top - self.textFieldInsets.bottom)
        }
    }
    
    @objc func editableTextNodeDidUpdateText(_ editableTextNode: ASEditableTextNode) {
        if let textInputNode = self.textInputNode {
            self.textPlaceholderNode.isHidden = editableTextNode.attributedText?.length ?? 0 != 0
            
            let constrainedSize = CGSize(width: self.frame.size.width, height: CGFloat.greatestFiniteMagnitude)
            let sendButtonSize = self.sendButton.bounds.size
            
            let textFieldHeight: CGFloat = min(115.0, max(20.0, ceil(textInputNode.measure(CGSize(width: constrainedSize.width - self.textFieldInsets.left - self.textFieldInsets.right - sendButtonSize.width - self.textInputViewInternalInsets.left - self.textInputViewInternalInsets.right, height: constrainedSize.height)).height)))
            if abs(textFieldHeight - textInputNode.frame.size.height) > CGFloat(FLT_EPSILON) {
                self.invalidateCalculatedLayout()
                self.updateHeight()
            }
        }
    }
    
    @objc func sendButtonPressed() {
        let text = self.textInputNode?.attributedText?.string ?? ""
        if !text.isEmpty {
            self.sendMessage()
        }
    }
    
    @objc func attachmentButtonPressed() {
        self.displayAttachmentMenu()
    }
    
    @objc func textInputBackgroundViewTap(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            if self.textInputNode == nil {
                self.loadTextInputNode()
            }
            
            self.textInputNode?.becomeFirstResponder()
        }
    }
    
    func animateTextSend() {
        /*if let textInputNode = self.textInputNode {
            let snapshot = textInputNode.view.snapshotViewAfterScreenUpdates(false)
            snapshot.frame = self.textInputBackgroundView.convertRect(textInputNode.view.bounds, fromView: textInputNode.view)
            self.textInputBackgroundView.addSubview(snapshot)
            UIView.animateWithDuration(0.3, animations: {
                snapshot.alpha = 0.0
                snapshot.transform = CGAffineTransformMakeTranslation(0.0, -20.0)
            }, completion: { _ in
                snapshot.removeFromSuperview()
            })
        }*/
    }
    
    /*override func hitTest(point: CGPoint, withEvent event: UIEvent!) -> UIView! {
        if let textInputNode = self.textInputNode where self.textInputBackgroundView.frame.contains(point) {
            return textInputNode.view
        }
        
        return super.hitTest(point, withEvent: event)
    }*/
}
