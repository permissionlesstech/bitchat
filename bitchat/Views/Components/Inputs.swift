//
//  Inputs.swift
//  bitchat
//
//  Created by Saputra on 21/08/25.
//

import SwiftUI

import SwiftUI

struct InfoBox: View {
    @Binding var text: String
    let placeholder: String?
    var isDisabled: Bool = false   // default editable
    
    var body: some View {
        let bgColor = isDisabled ? Color.gray.opacity(0.1) : Color.white
        let borderColor = isDisabled ? Color.gray.opacity(0.2) : Color.gray.opacity(0.4)

        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder ?? "")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .padding()
            }
            
            TextEditor(text: $text)
                .font(.footnote)
                .foregroundColor(isDisabled ? .gray : .primary)
                .padding(8)
                .frame(height: 200)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
        }
        .background(bgColor)
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(borderColor, lineWidth: 1)
        )
        .disabled(isDisabled)
    }
}


struct InputLabel: View {
    let title: String
    
    var body: some View {
        Text(title)
            .font(.body.weight(.bold))
            .foregroundColor(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RoundedTextField: View {
    @Binding var text: String
    let placeholder: String
    
    var body: some View {
        TextField(placeholder, text: $text)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemGray6))
            .cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20)
                .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                )
    }
}

struct Components_Previews: PreviewProvider {
    static var previews: some View {
        @State var text: String = ""
        VStack(alignment: .leading, spacing: 20) {
            InfoBox(text : $text, placeholder: "Description of the group")
            
            InputLabel(title: "Group Name")
            RoundedTextField(text: .constant(""), placeholder: "Name")
        }
        .padding()
    }
}

