#if os(iOS)
  import Photos
  import SwiftUI
  @MainActor
  struct ComposerLayoutFixture: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var composerFrame = CGRect.zero
    @State private var text = "hello"
    @State private var selection = "not selected"
    @State private var timer: Timer?
    @State private var picker = false
    @State private var source = UIImagePickerController.SourceType.camera
    @State private var sent = ""
    @FocusState private var focused: Bool
    @StateObject private var voice: VoiceRecordingViewModel
    private let viewModel: ChatViewModel
    private let models: LayoutFeatureModels
    private let actualPicker = ProcessInfo.processInfo.environment["ACTUAL_PICKER"] == "1"
    init() {
      _text = State(initialValue: ProcessInfo.processInfo.environment["LAYOUT_DRAFT"] ?? "hello")
      let recording = VoiceRecordingViewModel()
      recording.sessionProvider = { LayoutCapture() }
      _voice = StateObject(wrappedValue: recording)
      let vm = makeLayoutViewModel().viewModel
      viewModel = vm
      // The displayed channel can change without invoking relay subscriptions.
      // Media availability is controlled separately by this fixture's view model.
      models = makeLayoutFeatureModels(for: vm, displayLocationManager: makeLayoutLocationManager())
    }
    private var dynamicTypeName: String {
      if dynamicTypeSize == .large { return "large" }
      if dynamicTypeSize == .accessibility5 { return "accessibility5" }
      return "unexpected \(String(describing: dynamicTypeSize))"
    }
    private var composerBoundsValue: String {
      // String(Double) is locale-independent; SwiftUI interpolation localizes
      // decimal separators and would make the machine-readable report ambiguous.
      [composerFrame.minX, composerFrame.minY, composerFrame.width, composerFrame.height]
        .map { String(Double($0)) }.joined(separator: ",")
    }
    var body: some View {
      VStack {
        Group {
          Text("Language: " + (Bundle.main.preferredLocalizations.first ?? "unknown")
            + " Direction: " + (layoutDirection == .rightToLeft ? "rtl" : "ltr"))
            .accessibilityIdentifier("languageDirection")
          Text("Dynamic Type: " + dynamicTypeName)
            .accessibilityIdentifier("dynamicType")
          Text("Composer bounds")
            .accessibilityIdentifier("composerBounds")
            .accessibilityValue(composerBoundsValue)
          if actualPicker {
            Text("Photo permission: \(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)")
            Text(selection).accessibilityIdentifier("selection")
            Text("Draft: " + text).accessibilityIdentifier("draft")
          }
          Text("Sent: " + sent).accessibilityIdentifier("sent")
          Text(
            picker ? (source == .camera ? "camera requested" : "library requested") : "no picker")
          Button("Empty draft") { text = "" }
          Button("Fill draft") {
            text = "hello"
            picker = false
          }
          Button("No media context") {
            let channel = ChannelID.location(GeohashChannel(level: .block, geohash: "s000000"))
            viewModel.activeChannel = channel
            models.locationChannelsModel.select(channel)
          }
          Button("Start synthetic recording") {
            voice.start(shouldShow: true)
          }
          Text(
            voice.state.isActive
              ? "capture active"
              : (voice.state.alertMessage.isEmpty ? "capture inactive" : "capture error"))
        }.font(.system(size: 12))
        Spacer()
        installLayoutEnvironment(
          ContentComposerView(
            messageText: $text, isTextFieldFocused: $focused,
            voiceRecordingVM: voice, autocompleteDebounceTimer: $timer,
            onSendMessage: {
              sent = text
              text = ""
            }, showImagePicker: $picker, imagePickerSourceType: $source), featureModels: models
        )
        .frame(width: ProcessInfo.processInfo.environment["NARROW"] == "1" ? 280 : 390)
        .background(GeometryReader { geometry in
          Color.clear
            .onAppear { composerFrame = geometry.frame(in: .global) }
            .onChange(of: geometry.frame(in: .global)) { composerFrame = $0 }
        })
      }.fullScreenCover(isPresented: Binding(
        get: { actualPicker && picker },
        set: { picker = $0 }
      )) {
        ImagePickerView(sourceType: .photoLibrary) { image in
          selection = image.map {
            "selected \(Int($0.size.width))x\(Int($0.size.height)) "
              + (matchesFixturePhoto($0) ? "fixture pattern matched" : "wrong image content")
          } ?? "cancelled"
          picker = false
        }.ignoresSafeArea()
      }.environment(
        \.appTheme, ProcessInfo.processInfo.environment["GLASS"] == "1" ? .liquidGlass : .matrix)
    }
  }
  private func matchesFixturePhoto(_ image: UIImage) -> Bool {
    guard image.size == CGSize(width: 96, height: 64), let cgImage = image.cgImage,
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
    let width = 96
    let height = 64
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let decoded = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return false }
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
      return true
    }
    guard decoded else { return false }
    // Sample quadrant centers after decoding; encoded bytes can change in Photos.
    let samples = [
      (24, 16, [230, 20, 170]), (72, 16, [20, 180, 230]),
      (24, 48, [240, 200, 20]), (72, 48, [30, 190, 70])
    ]
    return samples.allSatisfy { x, y, expected in
      let offset = (y * width + x) * 4
      return (0..<3).allSatisfy { abs(Int(pixels[offset + $0]) - expected[$0]) <= 12 }
        && pixels[offset + 3] >= 250
    }
  }
  @MainActor
  final class LayoutCapture: VoiceCaptureSession {
    var isLive: Bool { false }
    func requestPermission() async -> Bool { true }
    func start() async throws {}
    func finish() async -> URL? { nil }
    func cancel() async {}
    func panicCancelSynchronously() {}
  }
#endif
