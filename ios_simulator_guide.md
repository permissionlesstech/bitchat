# 📱 Running BitChat in iOS Simulator

## What's Currently Open:
✅ Xcode is open  
✅ BitChat project is loaded  
✅ iOS Simulator is running (iPhone 16 Pro)  

## Next Steps in Xcode:

### 1. Select the Correct Scheme and Destination
1. In Xcode, look at the **toolbar** at the top
2. Click on the **scheme selector** (should show "bitchat" or similar)
3. **Select "bitchat_iOS"** from the dropdown
4. Click on the **destination selector** (right of the scheme)
5. **Choose "iPhone 16 Pro"** or any iOS Simulator device

### 2. Build and Run
- **Press ⌘+R** or click the **▶️ Play button**
- Wait for the build to complete
- The app should launch in the iOS Simulator

## If You See Errors:

### "No destinations found"
- Go to **Product → Destination → iOS Simulator**
- Select any iPhone simulator from the list

### "iOS version not installed"
- Go to **Xcode → Settings → Platforms**
- Download the missing iOS version
- Or select an iOS Simulator with a version you have installed

### "Build failed"
- Try **Product → Clean Build Folder** first
- Then **Product → Build** again

## Alternative: Use GUI Method
1. **Right-click** on "bitchat_iOS" in the project navigator
2. **Select "Build bitchat_iOS"**
3. Once built, **right-click** again
4. **Select "Run bitchat_iOS"**

## Keyboard Shortcuts:
- **⌘+R**: Build and Run
- **⌘+B**: Build only  
- **⌘+Shift+K**: Clean build folder
- **⌘+U**: Run tests

## What to Test in Simulator:
✅ App launches successfully  
✅ UI renders correctly  
✅ File sharing interface (though Bluetooth won't work)  
✅ Navigation and basic functionality  
❌ Real Bluetooth mesh (simulator limitation)  