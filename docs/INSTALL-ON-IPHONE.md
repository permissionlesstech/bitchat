# Installing bitchat on an iPhone with a Mac

This guide is for people who want bitchat on their iPhone and are not developers.
One script does the technical work. You only need to tap a few buttons on your
iPhone and Mac when the script asks.

> **Easiest option first:** if bitchat is available in the App Store in your
> country, install it from there. You don't need this guide.

## Why this isn't one tap like Android

On Android you can download an `.apk` file and install it. Apple doesn't allow
that on iPhone. An app not from the App Store must be **built on a Mac** and
**signed with your own Apple Account**. The script automates all of that. What
Apple still requires you to do by hand is listed in [Your part](#your-part).

## What you need

| You need | Notes |
|---|---|
| A Mac | Running a macOS version that supports the current Xcode. |
| Xcode | Free from the Mac App Store. It is a large download, so leave plenty of free disk space (plan for 40 GB or more). |
| An Apple Account | Your regular free Apple Account (the one you use for the App Store) works. |
| A USB cable | To connect the iPhone to the Mac. |
| An iPhone on iOS 16 or newer | |
| Internet access | To download the code and for Apple to sign the app. |

## Quick start

1. Open **Terminal** on your Mac (press ⌘ Space, type `Terminal`, press Return).
2. Copy this line, paste it into Terminal, and press Return:

   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/clustercoder/bitchat/main/scripts/install-on-iphone.sh)
   ```

3. Follow what the script prints. When it says **[press Enter]**, do what it
   asks on your iPhone or Mac, then come back to Terminal and press Return.

The script downloads the bitchat source to a `bitchat` folder in your home
folder. If you already have a copy of the repository, you can run it from there:

```bash
cd bitchat
bash scripts/install-on-iphone.sh
```

The first run takes 15–30 minutes, most of it building the app. Later runs are
faster.

## What the script does for you

| Step | What happens |
|---|---|
| Checks Xcode | Opens the App Store page if Xcode is missing and finishes Xcode's first-time setup. |
| Gets the code | Downloads bitchat to `~/bitchat`, or updates that copy on later runs. If you run the script from your own checkout, it builds that checkout as it is. |
| Sets up signing | Finds your Apple Development certificate and Team ID and writes `Configs/Local.xcconfig`. This gives the app an ID that belongs to you (`chat.bitchat.<your Team ID>`). |
| Finds your iPhone | Detects the connected iPhone and asks you to pick one if there are several. |
| Pairs | Connects the Mac to the iPhone for development. |
| Checks Developer Mode | Waits until you've turned it on, and asks again if the install says it is off. |
| Builds | Builds the app for your iPhone and registers the iPhone with your Apple Account. |
| Installs | Copies the app to your iPhone. If the first attempt fails, it retries automatically. |
| Opens the app | Starts bitchat on the iPhone, or tells you how to trust it first. |

## Your part

These are the only things you do by hand. The script stops and explains each
one when it gets there.

### 1. Install Xcode (first time only)

If Xcode is missing, the script opens its App Store page. Install it and **open
it once**. If Xcode asks to install extra components, choose iOS. Then go back to
Terminal and press Return.

### 2. Type your Mac password (first time only)

Xcode needs a one-time setup and a license agreement, and both require your Mac
login password. Characters don't appear in Terminal while you type the password.
That's normal. Type it and press Return.

### 3. Sign in to Xcode with your Apple Account (first time only)

If the script says no certificate was found:

1. Open **Xcode**, then go to **Xcode › Settings…** (⌘,) and choose **Accounts**.
2. Click **+**, choose **Apple Account**, and sign in.
3. Select your account, click **Manage Certificates…**, click **+** and choose
   **Apple Development**.
4. Go back to Terminal and press Return.

### 4. Connect and trust the Mac

1. Plug the iPhone into the Mac with the cable and **unlock** it.
2. When the iPhone asks **"Trust This Computer?"**, tap **Trust** and enter your
   iPhone passcode.

### 5. Turn on Developer Mode (first time only)

> **The Developer Mode switch is hidden** until a Mac has tried to use the
> iPhone for development. If you look before the script reaches this step,
> you won't find it. Wait for the script to ask.

1. On the iPhone, open **Settings › Privacy & Security**, scroll down, and tap
   **Developer Mode**.
2. Switch it **on** and tap **Restart**.
3. When the iPhone restarts, unlock it, tap **Turn On**, and enter your passcode.
4. Keep the cable plugged in, go back to Terminal, and press Return.

If you still don't see Developer Mode, unplug the cable, plug it back in, press
Return in Terminal, and check again.

### 6. Trust yourself as the developer

The first time bitchat is installed, iOS won't open it until you trust the
certificate it was signed with:

1. Open **Settings › General › VPN & Device Management**.
2. Under **Developer App**, tap your Apple Development profile (it shows your
   Apple Account email).
3. Tap **Trust**, then **Trust** again. If it says **Verify App** instead, tap
   it. This needs internet.
4. Go back to Terminal and press Return. The script opens bitchat.

If bitchat won't open after you run the script again later, repeat this step.

### 7. Allow Bluetooth

When bitchat opens, allow **Bluetooth**. The offline mesh needs it. Allowing
Location is optional and only used for location-based channels.

## Renewing every 7 days (free Apple Accounts)

Apps you sign with a free Apple Account **stop opening after 7 days**. To renew:

1. Connect the iPhone to the Mac and unlock it.
2. Run the script again.

Your chats and settings are kept, because the app keeps the same ID. If you used
the Quick start command, running it again also updates bitchat to the latest
code. If you run the script from your own copy of the repository, update that
copy yourself first (for example with `git pull`).

With a paid Apple Developer Program membership, the app lasts a year instead of
7 days.

## Troubleshooting

| Message or symptom | What to do |
|---|---|
| `No iPhone found` | Use a cable that carries data (some charge-only cables don't), unlock the iPhone, and tap **Trust** if asked. |
| `Pairing did not complete` | Unlock the iPhone, press Return, and watch for the **Trust This Computer?** prompt. |
| Developer Mode isn't in Settings | See [step 5](#5-turn-on-developer-mode-first-time-only). Reconnect the cable and press Return so the script tries again. |
| `Xcode is not signed in to your Apple Account` | Do [step 3](#3-sign-in-to-xcode-with-your-apple-account-first-time-only). |
| `maximum App ID limit` | Free accounts can only create a few new app IDs each week. Wait up to 7 days. |
| `iPhone runs a newer iOS than this Xcode supports` | Update Xcode from the App Store, then run the script again. |
| `Install failed` | Close bitchat on the iPhone, unlock it, and run the script again. |
| The app installs but won't open | Do [step 6](#6-trust-yourself-as-the-developer). |
| The app stopped opening after a week | Run the script again. See [Renewing every 7 days](#renewing-every-7-days-free-apple-accounts). |

The script prints the location of the full build log. Include that log if you
ask for help.

## What the script changes on your Mac

- `~/bitchat`: the downloaded source, unless you run the script from your own checkout.
- `Configs/Local.xcconfig` inside the source: your signing settings. Git ignores
  this file. If it already exists for a different team, the old file is kept as
  `Local.xcconfig.backup-<date>`.
- `.DerivedData/` inside the source: build output. You can delete it at any time.
- With your password, it finishes Xcode's first-time setup and, if needed,
  points the command-line tools at Xcode.

The script doesn't change any tracked source files.

To remove everything, delete bitchat from the iPhone like any other app and
delete the `~/bitchat` folder.

## Options for advanced users

```text
--team TEAM_ID   Sign with this Team ID instead of detecting it.
--device ID      Install on this iPhone (name, UDID, or CoreDevice identifier).
--source DIR     Build this checkout instead of downloading one.
BITCHAT_REPO_URL Repository to clone (default: https://github.com/clustercoder/bitchat.git).
```

To check that the source you build is the same as an official release, see
[Verifying a build](VERIFYING-A-BUILD.md).
