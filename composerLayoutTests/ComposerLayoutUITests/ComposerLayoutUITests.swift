import XCTest

final class ComposerLayoutUITests: XCTestCase {
  private var activeApp: XCUIApplication?

  override func record(_ issue: XCTIssue) {
    if let app = activeApp, app.state == .runningForeground {
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "App accessibility hierarchy at failure"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.lifetime = .keepAlways
      add(screenshot)
    }
    super.record(issue)
  }

  override func tearDown() {
    activeApp?.terminate()
    activeApp = nil
    super.tearDown()
  }

  func testActualPhotoPickerMatrixOrdinary() { checkActualPhotoPicker(glass: false, large: false) }
  func testActualPhotoPickerMatrixLarge() { checkActualPhotoPicker(glass: false, large: true) }
  func testActualPhotoPickerGlassOrdinary() { checkActualPhotoPicker(glass: true, large: false) }
  func testActualPhotoPickerGlassLarge() { checkActualPhotoPicker(glass: true, large: true) }
  private func checkActualPhotoPicker(glass: Bool, large: Bool) {
    continueAfterFailure = false
    let app = XCUIApplication()
    activeApp = app
    app.launchEnvironment = ["CI": "1", "ACTUAL_PICKER": "1", "GLASS": glass ? "1" : "0", "NARROW": "1"]
    app.launchArguments = [
      "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-UIPreferredContentSizeCategoryName",
      large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"
    ]
    app.launch()
    assertDynamicType(app, large: large)
    XCTAssertFalse(app.alerts.firstMatch.exists)
    XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    let camera = app.buttons["attach photo"]
    XCTAssertTrue(camera.waitForExistence(timeout: 8))
    camera.tap()
    let cancel = pickerCancel(in: app)
    XCTAssertTrue(
      cancel.waitForExistence(timeout: 8), "Actual picker must present without a permission workflow")
    XCTAssertFalse(app.alerts.firstMatch.exists)
    XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    cancel.tap()
    XCTAssertTrue(app.staticTexts["cancelled"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Draft: hello"].exists)
    camera.tap()
    XCTAssertTrue(cancel.waitForExistence(timeout: 8))
    // This is the system picker's informational banner, not a permission
    // alert. At accessibility XXXL it fills the viewport above the photos.
    let notice = pickerNotice(in: app)
    if notice.exists {
      let close = notice.buttons["Close"].firstMatch
      XCTAssertTrue(close.exists)
      close.tap()
    }
    XCTAssertFalse(app.alerts.firstMatch.exists)
    XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    let photos = pickerPhotos(in: app)
    let photo = photos.firstMatch
    XCTAssertTrue(photo.waitForExistence(timeout: 5), "Seeded synthetic photo must be visible")
    for candidate in photos.allElementsBoundByIndex {
      print("PICKER_IMAGE label=\(candidate.label) frame=\(candidate.frame)")
    }
    XCTAssertGreaterThan(photo.frame.width, 0)
    XCTAssertGreaterThan(photo.frame.height, 0)
    XCTAssertTrue(app.frame.contains(photo.frame), "Seeded thumbnail must be on screen")
    // The system picker exposes a virtual accessibility thumbnail; deliver a
    // real coordinate tap at its measured center rather than an AX press.
    photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(
      app.staticTexts["selected 96x64 fixture pattern matched"].waitForExistence(timeout: 8),
      "Production picker delegate must return the seeded dimensions and decoded quadrant colors")
    XCTAssertFalse(cancel.exists)
    XCTAssertTrue(
      app.staticTexts["Photo permission: 0"].exists,
      "Selecting one photo must not require full library authorization")
    XCTAssertTrue(app.staticTexts["Draft: hello"].exists)
    app.buttons["send message"].tap()
    XCTAssertTrue(app.staticTexts["Sent: hello"].waitForExistence(timeout: 3))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.lifetime = .keepAlways
    add(shot)
  }

  func testAccessibilityXXXL() { check(large: true, glass: false, narrow: true) }
  func testAccessibilityXXXLWide() { check(large: true, glass: false, narrow: false) }
  func testGlassAccessibilityXXXLWide() { check(large: true, glass: true, narrow: false) }
  func testOrdinaryNarrow() { check(large: false, glass: false, narrow: true) }
  func testGlassOrdinary() { check(large: false, glass: true, narrow: false) }
  func testGlassAccessibilityXXXL() { check(large: true, glass: true, narrow: true) }
  func testOrdinary() { check(large: false, glass: false, narrow: false) }
  func testGlassOrdinaryNarrow() { check(large: false, glass: true, narrow: true) }
  func testMicrophoneGestureUsesSyntheticCapture() {
    continueAfterFailure = false
    let app = XCUIApplication()
    activeApp = app
    app.launchEnvironment["CI"] = "1"
    app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    XCTAssertTrue(app.buttons["Empty draft"].waitForExistence(timeout: 10))
    app.buttons["Empty draft"].tap()
    // Exercise the real gesture before any synthetic-start button is used.
    app.buttons["record voice note"].press(forDuration: 1)
    // The inert backend returns no file; this error establishes that the real gesture finished capture.
    XCTAssertTrue(app.staticTexts["capture error"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.alerts.firstMatch.exists)
    XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["Empty draft"].waitForExistence(timeout: 10))
    app.buttons["Empty draft"].tap()
    app.buttons["Start synthetic recording"].tap()
    XCTAssertTrue(app.staticTexts["capture active"].waitForExistence(timeout: 3))
    app.buttons["cancel"].tap()
    XCTAssertTrue(app.staticTexts["capture inactive"].waitForExistence(timeout: 3))
  }
  func testNarrowLargeTextEditing() { checkTyping(glass: false) }
  func testNarrowGlassLargeTextEditing() { checkTyping(glass: true) }
  private func checkTyping(glass: Bool) {
    continueAfterFailure = false
    let app = XCUIApplication()
    activeApp = app
    app.launchEnvironment = ["CI": "1", "NARROW": "1", "GLASS": glass ? "1" : "0"]
    app.launchArguments = [
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
    ]
    app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    assertDynamicType(app, large: true)
    let field = app.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.lifetime = .keepAlways
    add(shot)
    XCTAssertGreaterThan(field.frame.width, 0)
    assertContained([field], in: app)
    app.buttons["Empty draft"].tap()
    field.tap()
    field.typeText("hello!")
    XCTAssertEqual(field.value as? String, "hello!")
    app.buttons["send message"].tap()
    XCTAssertTrue(app.staticTexts["Sent: hello!"].waitForExistence(timeout: 3))
  }
  // English system-picker selectors are centralized so an OS change produces
  // one diagnostic failure rather than silently selecting a different element.
  private func pickerCancel(in app: XCUIApplication) -> XCUIElement {
    app.buttons["Cancel"].firstMatch
  }
  private func pickerNotice(in app: XCUIApplication) -> XCUIElement {
    app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Private Access to Photos,'")).firstMatch
  }
  private func pickerPhotos(in app: XCUIApplication) -> XCUIElementQuery {
    app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo' OR label BEGINSWITH 'Image'"))
  }
  func testArabicMatrixOrdinary() { checkLocalized(language: "ar", glass: false, large: false) }
  func testArabicMatrixLarge() { checkLocalized(language: "ar", glass: false, large: true) }
  func testArabicGlassOrdinary() { checkLocalized(language: "ar", glass: true, large: false) }
  func testArabicGlassLarge() { checkLocalized(language: "ar", glass: true, large: true) }
  func testHebrewMatrixOrdinary() { checkLocalized(language: "he", glass: false, large: false) }
  func testHebrewMatrixLarge() { checkLocalized(language: "he", glass: false, large: true) }
  func testHebrewGlassOrdinary() { checkLocalized(language: "he", glass: true, large: false) }
  func testHebrewGlassLarge() { checkLocalized(language: "he", glass: true, large: true) }
  func testGermanMatrixOrdinary() { checkLocalized(language: "de", glass: false, large: false) }
  func testGermanMatrixLarge() { checkLocalized(language: "de", glass: false, large: true) }
  func testGermanGlassOrdinary() { checkLocalized(language: "de", glass: true, large: false) }
  func testGermanGlassLarge() { checkLocalized(language: "de", glass: true, large: true) }
  // Literal expected strings are independent checks of the shipped catalog,
  // not labels read back from the fixture under test.
  private func checkLocalized(language: String, glass: Bool, large: Bool) {
    continueAfterFailure = false
    let labels: [String]
    let draft: String
    switch language {
    case "ar":
      labels = ["إرفاق صورة", "إرسال رسالة", "تسجيل ملاحظة صوتية", "رسالة #mesh — عام، قريب", "رسالة #s000000 — عام"]
      draft = "مرحبا ABC 123"
    case "he":
      labels = ["צירוף תמונה", "שלח הודעה", "הקלטת הערה קולית", "הודעה ל-#mesh — ציבורי, קרוב", "הודעה ל-#s000000 — ציבורי"]
      draft = "שלום ABC 123"
    case "de":
      labels = ["foto anhängen", "nachricht senden", "sprachnachricht aufnehmen", "nachricht an #mesh — öffentlich, in der nähe", "nachricht an #s000000 — öffentlich"]
      draft = "Grüße ABC 123"
    default: XCTFail("Unsupported layout language"); return
    }
    let rtl = language != "de"
    // Expect the identifier to be direction-isolated in the RTL placeholder.
    let channelTarget = rtl ? "\u{2068}s000000\u{2069}" : "s000000"
    let expectedChannel = labels[4].replacingOccurrences(of: "s000000", with: channelTarget)
    let app = XCUIApplication()
    activeApp = app
    app.launchEnvironment = ["CI": "1", "NARROW": "1", "GLASS": glass ? "1" : "0", "LAYOUT_DRAFT": draft]
    app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language,
      "-UIPreferredContentSizeCategoryName",
      large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
    app.launch()
    assertDynamicType(app, large: large)
    XCTAssertTrue(app.staticTexts["Language: \(language) Direction: \(rtl ? "rtl" : "ltr")"].exists,
                  "Actual bundle language and SwiftUI layout direction must match the requested locale")
    let field = app.textFields.firstMatch
    let camera = app.buttons[labels[0]]
    let send = app.buttons[labels[1]]
    let mic = app.buttons[labels[2]]
    XCTAssertTrue(camera.waitForExistence(timeout: 5))
    XCTAssertTrue(send.exists)
    XCTAssertEqual(field.value as? String, draft)
    assertLocalizedRow(field: field, camera: camera, action: send, app: app, rtl: rtl, large: large)
    camera.tap()
    XCTAssertTrue(app.staticTexts["library requested"].waitForExistence(timeout: 3))
    send.tap()
    XCTAssertTrue(app.staticTexts["Sent: " + draft].waitForExistence(timeout: 3))
    XCTAssertTrue(mic.exists)
    XCTAssertEqual(field.placeholderValue, labels[3], "Localized mesh placeholder must actually load")
    assertLocalizedRow(field: field, camera: camera, action: mic, app: app, rtl: rtl, large: large)
    // Exercise editable text in the localized environment without depending on
    // availability of individual non-Latin keys in the simulator keyboard.
    field.tap()
    field.typeText("123")
    XCTAssertEqual(field.value as? String, "123")
    XCTAssertTrue(send.exists)
    send.tap()
    XCTAssertTrue(app.staticTexts["Sent: 123"].waitForExistence(timeout: 3))
    app.buttons["No media context"].tap()
    XCTAssertFalse(camera.exists)
    XCTAssertTrue(send.exists)
    XCTAssertFalse(send.isEnabled)
    let channelPlaceholder = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "placeholderValue == %@", expectedChannel), object: field)
    let placeholderResult = XCTWaiter.wait(for: [channelPlaceholder], timeout: 3)
    print("CHANNEL_PLACEHOLDER actual=\(String(reflecting: field.placeholderValue)) expected=\(String(reflecting: expectedChannel))")
    XCTAssertEqual(placeholderResult, .completed, "Localized channel placeholder must actually load")
    assertContained([field, send], in: app)
    app.buttons["Fill draft"].tap()
    XCTAssertTrue(send.isEnabled)
    XCTAssertFalse(field.frame.intersects(send.frame), "Text field and send-only control must not overlap")
    assertContained([field, send], in: app)
    if rtl { XCTAssertLessThanOrEqual(send.frame.maxX, field.frame.minX + 1) }
    else { XCTAssertLessThanOrEqual(field.frame.maxX, send.frame.minX + 1) }
    send.tap()
    XCTAssertTrue(app.staticTexts["Sent: hello"].waitForExistence(timeout: 3))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.lifetime = .keepAlways
    add(shot)
  }
  private func assertLocalizedRow(
    field: XCUIElement, camera: XCUIElement, action: XCUIElement,
    app: XCUIApplication, rtl: Bool, large: Bool
  ) {
    print("LOCALIZED_ROW rtl=\(rtl) field=\(field.frame) attachment=\(camera.frame) action=\(action.frame)")
    XCTAssertFalse(camera.frame.intersects(action.frame), "Attachment and action controls must not overlap")
    XCTAssertFalse(field.frame.intersects(camera.frame), "Text field and attachment must not overlap")
    XCTAssertFalse(field.frame.intersects(action.frame), "Text field and action must not overlap")
    assertVisibleBounds(camera, large: large)
    assertVisibleBounds(action, large: large)
    assertContained([field, camera, action], in: app)
    if rtl {
      XCTAssertLessThanOrEqual(action.frame.maxX, camera.frame.minX + 1, "RTL actions must mirror LTR ordering")
      XCTAssertLessThanOrEqual(camera.frame.maxX, field.frame.minX + 1)
    } else {
      XCTAssertLessThanOrEqual(field.frame.maxX, camera.frame.minX + 1)
      XCTAssertLessThanOrEqual(camera.frame.maxX, action.frame.minX + 1)
    }
  }
  private func assertDynamicType(_ app: XCUIApplication, large: Bool) {
    let expected = "Dynamic Type: " + (large ? "accessibility5" : "large")
    XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 10), "Fixture must receive the requested Dynamic Type environment")
  }
  private func assertContained(_ controls: [XCUIElement], in app: XCUIApplication) {
    let bounds = app.staticTexts["composerBounds"]
    // The element is normally already present. Avoid a polling wait for each
    // control, but retain a bounded fallback when the fixture is not ready.
    XCTAssertTrue(bounds.exists || bounds.waitForExistence(timeout: 3))
    let components = (bounds.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
    guard components.count == 4 else {
      XCTFail("Missing measured composer frame: \(String(describing: bounds.value))")
      return
    }
    let frame = CGRect(x: components[0], y: components[1], width: components[2], height: components[3])
    XCTAssertGreaterThan(frame.width, 0)
    XCTAssertGreaterThan(frame.height, 0)
    let screen = app.frame
    // Read fresh geometry for each assertion group; never cache across UI transitions.
    for control in controls {
      let controlFrame = control.frame
      XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(controlFrame),
                    "Control accessibility bounds \(controlFrame) must stay inside measured composer \(frame)")
      XCTAssertTrue(screen.contains(controlFrame), "Control accessibility bounds must remain on screen")
    }
  }
  private func assertVisibleBounds(_ control: XCUIElement, large: Bool) {
    if large {
      XCTAssertGreaterThan(control.frame.width, 36)
      XCTAssertGreaterThan(control.frame.height, 36)
    } else {
      // Accessibility can expose the icon rather than the full SwiftUI allocation.
      XCTAssertGreaterThan(control.frame.width, 0)
      XCTAssertGreaterThan(control.frame.height, 0)
      XCTAssertLessThanOrEqual(control.frame.width, 37)
      XCTAssertLessThanOrEqual(control.frame.height, 37)
    }
  }
  private func check(large: Bool, glass: Bool, narrow: Bool) {
    continueAfterFailure = false
    let app = XCUIApplication()
    activeApp = app
    app.launchEnvironment = ["CI": "1", "GLASS": glass ? "1" : "0", "NARROW": narrow ? "1" : "0"]
    app.launchArguments = [
      "-UIPreferredContentSizeCategoryName",
      large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"
    ]
    app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    assertDynamicType(app, large: large)
    let camera = app.buttons["attach photo"]
    let send = app.buttons["send message"]
    XCTAssertTrue(camera.waitForExistence(timeout: 10))
    XCTAssertTrue(send.exists)
    print(
      "GEOMETRY large=\(large) glass=\(glass) narrow=\(narrow) attachment=\(camera.frame) send=\(send.frame)"
    )
    XCTAssertFalse(
      camera.frame.intersects(send.frame), "Attachment and send controls must not overlap")
    if large {
      XCTAssertGreaterThan(
        camera.frame.width, 36, "Attachment accessibility bounds must grow with its Dynamic Type icon")
      XCTAssertGreaterThan(send.frame.width, 36)
    } else {
      XCTAssertEqual(camera.frame.width, 36, accuracy: 1)
    }
    assertVisibleBounds(camera, large: large)
    assertVisibleBounds(send, large: large)
    assertContained([camera, send], in: app)
    camera.tap()
    XCTAssertTrue(app.staticTexts["library requested"].waitForExistence(timeout: 3))
    app.buttons["Fill draft"].tap()
    camera.press(forDuration: 1)
    XCTAssertTrue(
      app.staticTexts["camera requested"].waitForExistence(timeout: 3),
      "One-second camera long press should request camera source")
    send.tap()
    XCTAssertTrue(app.staticTexts["Sent: hello"].waitForExistence(timeout: 3))
    let mic = app.buttons["record voice note"]
    XCTAssertTrue(mic.waitForExistence(timeout: 3))
    XCTAssertFalse(
      camera.frame.intersects(mic.frame), "Attachment and microphone controls must not overlap")
    assertVisibleBounds(mic, large: large)
    assertContained([camera, mic], in: app)
    app.buttons["Start synthetic recording"].tap()
    XCTAssertTrue(app.staticTexts["capture active"].waitForExistence(timeout: 3))
    app.buttons["cancel"].tap()
    XCTAssertTrue(app.staticTexts["capture inactive"].waitForExistence(timeout: 3))
    app.buttons["Fill draft"].tap()
    XCTAssertTrue(send.waitForExistence(timeout: 3))
    app.buttons["No media context"].tap()
    XCTAssertFalse(camera.exists)
    app.buttons["Empty draft"].tap()
    XCTAssertFalse(send.isEnabled)
    app.buttons["Fill draft"].tap()
    XCTAssertTrue(send.isEnabled)
    assertVisibleBounds(send, large: large)
    assertContained([send], in: app)
    XCTAssertFalse(app.textFields.firstMatch.frame.intersects(send.frame), "Text field and send-only control must not overlap")
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.lifetime = .keepAlways
    add(shot)
  }
}
