# Console Warnings Explanation

## Benign System Warnings

When running BitChat, you may see these warnings in the console. They are **harmless** and don't indicate any problems:

### 1. CFPrefsPlistSource Warning

```
Couldn't read values in CFPrefsPlistSource<0x...> (Domain: group.chat.bitchat, User: kCFPreferencesAnyUser, ByHost: Yes, Container: (null), Contents Need Refresh: Yes): Using kCFPreferencesAnyUser with a container is only allowed for System Containers, detaching from cfprefsd
```

**What it means**: This is a known Apple framework issue when using `UserDefaults` with app groups. The warning appears when the app shares data between the main app and the share extension.

**Impact**: None. App groups work correctly despite this warning.

**Can it be fixed?**: No. This is an Apple bug that has existed since iOS 8 and affects many production apps.

### 2. Failed to get or decode unavailable reasons

```
Failed to get or decode unavailable reasons
```

**What it means**: CoreBluetooth is checking why Bluetooth might be unavailable (airplane mode, Bluetooth off, etc.).

**Impact**: None. This is normal CoreBluetooth behavior.

**Can it be fixed?**: No. This is standard system behavior.

## Reducing Console Noise

If these warnings bother you during development:

1. In Xcode, edit your scheme
2. Add environment variable: `OS_ACTIVITY_MODE = disable`
3. Note: This will hide ALL system messages, not just these warnings

## Summary

These warnings are cosmetic issues in Apple's frameworks and don't affect the app's functionality. Many production iOS apps display similar warnings when using app groups or Bluetooth.