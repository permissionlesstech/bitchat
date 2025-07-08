//
//  ProtectedView.swift
//  bitchat
//
//  This is free and unencumbered software released into the public domain.
//  For more information, see <https://unlicense.org>
//

import SwiftUI

#if os(iOS)
import UIKit
public typealias PlatformViewRepresentable = UIViewRepresentable
#elseif os(macOS)
import AppKit
public typealias PlatformViewRepresentable = NSViewRepresentable
#endif

// MARK: - SwiftUI View Modifier
struct ScreenshotProtectionModifier: ViewModifier {
    let isProtected: Bool
    
    func body(content: Content) -> some View {
        if isProtected {
            ProtectedView(isProtected: isProtected) {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - SwiftUI Extension
extension View {
    func screenshotProtection(_ isProtected: Bool = true) -> some View {
        modifier(ScreenshotProtectionModifier(isProtected: isProtected))
    }
}

// MARK: - SwiftUI Wrapper

struct ProtectedView<Content: View>: PlatformViewRepresentable {
    let isProtected: Bool
    let content: Content
    
    init(isProtected: Bool = true, @ViewBuilder content: () -> Content) {
        self.isProtected = isProtected
        self.content = content()
    }
    
    #if os(iOS)
    
    func makeUIView(context: Context) -> UIView {
        let secureTextField = UITextField()
        secureTextField.isSecureTextEntry = true
        secureTextField.isUserInteractionEnabled = false
        
        guard let secureView = secureTextField.layer.sublayers?.first?.delegate as? UIView else {
            return UIView()
        }
        
        secureView.subviews.forEach { subview in
            subview.removeFromSuperview()
        }
        
        let hController = UIHostingController(rootView: self.content)
        hController.view.backgroundColor = .clear
        hController.view.translatesAutoresizingMaskIntoConstraints = false
        
        secureView.addSubview(hController.view)
        NSLayoutConstraint.activate([
            hController.view.topAnchor.constraint(equalTo: secureView.topAnchor),
            hController.view.bottomAnchor.constraint(equalTo: secureView.bottomAnchor),
            hController.view.leadingAnchor.constraint(equalTo: secureView.leadingAnchor),
            hController.view.trailingAnchor.constraint(equalTo: secureView.trailingAnchor)
        ])
        
        return secureView
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
    
    #elseif os(macOS)
    
    func makeNSView(context: Context) -> NSView {
        let hostingView = NSHostingView(rootView: content)
        return hostingView
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    #endif
}
