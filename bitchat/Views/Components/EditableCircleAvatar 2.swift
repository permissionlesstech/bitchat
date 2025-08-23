//
//  EditableCircleAvatar.swift
//  bitchat
//
//  Created by Saputra on 20/08/25.
//

import SwiftUI

struct EditableCircleAvatar: View {
    var image: Image? = nil
    var diameter: CGFloat = 84
    var onEdit: () -> Void = {}
    @Binding var color: Color

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(Color.gray.opacity(0.1))
                .frame(width: diameter, height: diameter)
                .overlay(
                    Group {
                        if let image { image.resizable().scaledToFill() }
                        else { Circle().fill(color).frame(width: diameter, height: diameter) }
                    }
                    .foregroundStyle(.secondary)
//                    .clipShape(Circle())
                )
                .overlay(Circle().stroke(Color.white, lineWidth: 8))

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    EditableCircleAvatar(color: .constant(.blue))
}
