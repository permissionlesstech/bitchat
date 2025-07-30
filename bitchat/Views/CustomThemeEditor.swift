//
// CustomThemeEditor.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import UniformTypeIdentifiers

struct CustomThemeEditor: View {
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    
    @State private var customTheme: BitchatTheme
    @State private var showingColorPicker = false
    @State private var selectedColorProperty: String = ""
    @State private var showingExportSheet = false
    @State private var showingImportSheet = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var alertTitle = ""
    
    init(editingTheme: BitchatTheme? = nil) {
        if let theme = editingTheme {
            _customTheme = State(initialValue: theme)
        } else {
            _customTheme = State(initialValue: BitchatTheme.createCustomTheme())
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with terminal styling
            HStack {
                Text("CUSTOM THEME EDITOR")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(themeManager.primaryTextColor(for: colorScheme))
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button("Import") {
                        showingImportSheet = true
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(themeManager.accentColor(for: colorScheme))
                    
                    Button("Export") {
                        showingExportSheet = true
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(themeManager.accentColor(for: colorScheme))
                    
                    Button("Save") {
                        saveTheme()
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(themeManager.accentColor(for: colorScheme))
                    
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(themeManager.secondaryTextColor(for: colorScheme))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(themeManager.secondaryBackgroundColor(for: colorScheme))
            
            // Divider
            Rectangle()
                .fill(themeManager.dividerColor(for: colorScheme))
                .frame(height: 1)
            
            // Content
            ScrollView {
                VStack(spacing: 20) {
                    // Theme Preview
                    ThemePreviewSection(theme: customTheme)
                    
                    // Basic Info
                    BasicInfoSection(theme: $customTheme)
                    
                    // Color Sections
                    BackgroundColorsSection(theme: $customTheme, onColorTap: { property in
                        selectedColorProperty = property
                        showingColorPicker = true
                    })
                    
                    TextColorsSection(theme: $customTheme, onColorTap: { property in
                        selectedColorProperty = property
                        showingColorPicker = true
                    })
                    
                    AccentColorsSection(theme: $customTheme, onColorTap: { property in
                        selectedColorProperty = property
                        showingColorPicker = true
                    })
                    
                    SignalColorsSection(theme: $customTheme, onColorTap: { property in
                        selectedColorProperty = property
                        showingColorPicker = true
                    })
                    
                    UIColorsSection(theme: $customTheme, onColorTap: { property in
                        selectedColorProperty = property
                        showingColorPicker = true
                    })
                }
                .padding(16)
            }
            .background(themeManager.backgroundColor(for: colorScheme))
        }
        .sheet(isPresented: $showingColorPicker) {
            IntelligentColorPicker(
                color: bindingForProperty(selectedColorProperty),
                propertyName: selectedColorProperty
            )
        }
        .fileExporter(
            isPresented: $showingExportSheet,
            document: ThemeDocument(theme: customTheme),
            contentType: .json,
            defaultFilename: "\(customTheme.name.replacingOccurrences(of: " ", with: "_")).json"
        ) { result in
            switch result {
            case .success:
                showAlert(title: "Exported", message: "Theme exported successfully")
            case .failure(let error):
                showAlert(title: "Export Failed", message: error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $showingImportSheet,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(alertTitle, isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func bindingForProperty(_ property: String) -> Binding<CodableColor> {
        switch property {
        case "backgroundColor":
            return $customTheme.backgroundColor
        case "secondaryBackgroundColor":
            return $customTheme.secondaryBackgroundColor
        case "primaryTextColor":
            return $customTheme.primaryTextColor
        case "secondaryTextColor":
            return $customTheme.secondaryTextColor
        case "systemTextColor":
            return $customTheme.systemTextColor
        case "accentColor":
            return $customTheme.accentColor
        case "mentionColor":
            return $customTheme.mentionColor
        case "hashtagColor":
            return $customTheme.hashtagColor
        case "excellentSignalColor":
            return $customTheme.excellentSignalColor
        case "goodSignalColor":
            return $customTheme.goodSignalColor
        case "fairSignalColor":
            return $customTheme.fairSignalColor
        case "weakSignalColor":
            return $customTheme.weakSignalColor
        case "poorSignalColor":
            return $customTheme.poorSignalColor
        case "dividerColor":
            return $customTheme.dividerColor
        case "unreadMessageColor":
            return $customTheme.unreadMessageColor
        case "favoriteColor":
            return $customTheme.favoriteColor
        default:
            return $customTheme.backgroundColor
        }
    }
    
    private func saveTheme() {
        guard !customTheme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert(title: "Invalid Name", message: "Theme name cannot be empty")
            return
        }
        
        themeManager.addCustomTheme(customTheme)
        showAlert(title: "Saved", message: "Custom theme saved successfully") {
            dismiss()
        }
    }
    
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            // Start accessing security-scoped resource
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            
            defer {
                if isSecurityScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                let data = try Data(contentsOf: url)
                
                // First, let's validate it's valid JSON
                guard let jsonString = String(data: data, encoding: .utf8) else {
                    showAlert(title: "Import Failed", message: "File is not valid UTF-8 text")
                    return
                }
                
                // Check if it's valid JSON at all
                do {
                    _ = try JSONSerialization.jsonObject(with: data, options: [])
                } catch {
                    showAlert(title: "Import Failed", message: "File is not valid JSON: \(error.localizedDescription)")
                    return
                }
                
                // Try to decode as BitchatTheme
                let importedTheme: BitchatTheme
                do {
                    importedTheme = try JSONDecoder().decode(BitchatTheme.self, from: data)
                } catch {
                    // Provide detailed error information
                    var errorMessage = "Theme decode failed: "
                    if let decodingError = error as? DecodingError {
                        switch decodingError {
                        case .keyNotFound(let key, _):
                            errorMessage += "Missing required field '\(key.stringValue)'"
                        case .typeMismatch(_, let context):
                            errorMessage += "Type mismatch at '\(context.codingPath.map { $0.stringValue }.joined(separator: "."))'"
                        case .valueNotFound(_, let context):
                            errorMessage += "Missing value at '\(context.codingPath.map { $0.stringValue }.joined(separator: "."))'"
                        case .dataCorrupted(let context):
                            errorMessage += "Data corrupted at '\(context.codingPath.map { $0.stringValue }.joined(separator: "."))'"
                        @unknown default:
                            errorMessage += error.localizedDescription
                        }
                    } else {
                        errorMessage += error.localizedDescription
                    }
                    showAlert(title: "Import Failed", message: errorMessage)
                    return
                }
                
                // Generate new ID to avoid conflicts
                var newTheme = importedTheme
                newTheme.id = "custom_\(UUID().uuidString)"
                
                customTheme = newTheme
                showAlert(title: "Imported", message: "Theme '\(newTheme.name)' imported successfully")
            } catch {
                showAlert(title: "Import Failed", message: "Could not read file: \(error.localizedDescription)")
            }
        case .failure(let error):
            showAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }
    
    private func showAlert(title: String, message: String, completion: (() -> Void)? = nil) {
        alertTitle = title
        alertMessage = message
        showingAlert = true
        
        if let completion = completion {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                completion()
            }
        }
    }
}

// MARK: - Theme Preview Section

struct ThemePreviewSection: View {
    let theme: BitchatTheme
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PREVIEW")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(themeManager.secondaryTextColor(for: colorScheme))
            
            VStack(spacing: 8) {
                // Header preview
                HStack {
                    Text("bitchat")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.primaryTextColor.color)
                    
                    Spacer()
                    
                    Text("12:34")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryTextColor.color)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.backgroundColor.color)
                .cornerRadius(6)
                
                // Message preview
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("@user")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.mentionColor.color)
                        
                        Text("Hello world!")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.primaryTextColor.color)
                    }
                    
                    HStack {
                        Text("#general")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.hashtagColor.color)
                        
                        Text("Signal: ")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryTextColor.color)
                        
                        Circle()
                            .fill(theme.excellentSignalColor.color)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackgroundColor.color)
                .cornerRadius(6)
            }
        }
    }
}

// MARK: - Basic Info Section

struct BasicInfoSection: View {
    @Binding var theme: BitchatTheme
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BASIC INFO")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(themeManager.secondaryTextColor(for: colorScheme))
            
            VStack(spacing: 8) {
                HStack {
                    Text("Name:")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(themeManager.primaryTextColor(for: colorScheme))
                        .frame(width: 80, alignment: .leading)
                    
                    TextField("Theme name", text: $theme.name)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(themeManager.secondaryBackgroundColor(for: colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(themeManager.dividerColor(for: colorScheme), lineWidth: 1)
                        )
                        .foregroundColor(themeManager.primaryTextColor(for: colorScheme))
                }
                
                HStack {
                    Text("Description:")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(themeManager.primaryTextColor(for: colorScheme))
                        .frame(width: 80, alignment: .leading)
                    
                    TextField("Theme description", text: $theme.description)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(themeManager.secondaryBackgroundColor(for: colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(themeManager.dividerColor(for: colorScheme), lineWidth: 1)
                        )
                        .foregroundColor(themeManager.primaryTextColor(for: colorScheme))
                }
            }
        }
    }
}

// MARK: - Color Sections

struct BackgroundColorsSection: View {
    @Binding var theme: BitchatTheme
    let onColorTap: (String) -> Void
    
    var body: some View {
        ColorSection(
            title: "BACKGROUND COLORS",
            colors: [
                ("Background", theme.backgroundColor, "backgroundColor"),
                ("Secondary", theme.secondaryBackgroundColor, "secondaryBackgroundColor")
            ],
            onColorTap: onColorTap
        )
    }
}

struct TextColorsSection: View {
    @Binding var theme: BitchatTheme
    let onColorTap: (String) -> Void
    
    var body: some View {
        ColorSection(
            title: "TEXT COLORS",
            colors: [
                ("Primary", theme.primaryTextColor, "primaryTextColor"),
                ("Secondary", theme.secondaryTextColor, "secondaryTextColor"),
                ("System", theme.systemTextColor, "systemTextColor")
            ],
            onColorTap: onColorTap
        )
    }
}

struct AccentColorsSection: View {
    @Binding var theme: BitchatTheme
    let onColorTap: (String) -> Void
    
    var body: some View {
        ColorSection(
            title: "ACCENT COLORS",
            colors: [
                ("Accent", theme.accentColor, "accentColor"),
                ("Mention", theme.mentionColor, "mentionColor"),
                ("Hashtag", theme.hashtagColor, "hashtagColor")
            ],
            onColorTap: onColorTap
        )
    }
}

struct SignalColorsSection: View {
    @Binding var theme: BitchatTheme
    let onColorTap: (String) -> Void
    
    var body: some View {
        ColorSection(
            title: "SIGNAL COLORS",
            colors: [
                ("Excellent", theme.excellentSignalColor, "excellentSignalColor"),
                ("Good", theme.goodSignalColor, "goodSignalColor"),
                ("Fair", theme.fairSignalColor, "fairSignalColor"),
                ("Weak", theme.weakSignalColor, "weakSignalColor"),
                ("Poor", theme.poorSignalColor, "poorSignalColor")
            ],
            onColorTap: onColorTap
        )
    }
}

struct UIColorsSection: View {
    @Binding var theme: BitchatTheme
    let onColorTap: (String) -> Void
    
    var body: some View {
        ColorSection(
            title: "UI COLORS",
            colors: [
                ("Divider", theme.dividerColor, "dividerColor"),
                ("Unread", theme.unreadMessageColor, "unreadMessageColor"),
                ("Favorite", theme.favoriteColor, "favoriteColor")
            ],
            onColorTap: onColorTap
        )
    }
}

struct ColorSection: View {
    let title: String
    let colors: [(String, CodableColor, String)]
    let onColorTap: (String) -> Void
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(themeManager.secondaryTextColor(for: colorScheme))
            
            VStack(spacing: 8) {
                ForEach(colors, id: \.0) { name, color, property in
                    HStack {
                        Text(name)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(themeManager.primaryTextColor(for: colorScheme))
                            .frame(width: 80, alignment: .leading)
                        
                        Button(action: {
                            onColorTap(property)
                        }) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(color.color)
                                    .frame(width: 24, height: 16)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(themeManager.dividerColor(for: colorScheme), lineWidth: 1)
                                    )
                                
                                Text(String(format: "#%02X%02X%02X", 
                                           Int(color.red * 255), 
                                           Int(color.green * 255), 
                                           Int(color.blue * 255)))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(themeManager.secondaryTextColor(for: colorScheme))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(themeManager.secondaryBackgroundColor(for: colorScheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(themeManager.dividerColor(for: colorScheme), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                    }
                }
            }
        }
    }
}

// MARK: - Theme Document for Export

struct ThemeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    
    let theme: BitchatTheme
    
    init(theme: BitchatTheme) {
        self.theme = theme
    }
    
    init(configuration: ReadConfiguration) throws {
        theme = BitchatTheme.systemAuto
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(theme)
        return FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    CustomThemeEditor()
        .environmentObject(ThemeManager())
} 