# SwipeClean

A tiny photo-cleanup app for iOS and Android. Pick a month, then swipe through it one photo at a time — left to delete, right to keep, up to put it in a folder. Nothing is deleted until you review the pile and confirm.

## How it works

| Gesture | What happens |
| --- | --- |
| Swipe **left** | Marks the photo for deletion |
| Swipe **right** | Keeps it |
| Swipe **up** | Keeps it **and** adds it to your swipe-up album/folder |

Each gesture also has a button under the card, next to undo, favourite and share.

- **Months.** Photos are grouped by month. The list shows how far you've got through each one, and your progress is saved between launches.
- **Nothing is deleted by accident.** Marked photos pile up in the trash. Open it to tap any photo back out, then tap *Delete all* and confirm the system prompt. On Android they go to the system trash, where they stay for 30 days.
- **Undo** steps back one photo, including a swipe up.
- **Favourite** toggles the real Favourites flag in your photo library.

### Swipe-up album / folder

Tap the **↑ name** chip above the photo to choose where swiping up sends photos. You can pick an existing album/folder or type a new name. Your choice is remembered until you change it. Out of the box it's called **SwipeClean**.

- **iOS:** adds the photo to an album in Photos (created the first time you swipe up). The photo stays in your library as well; albums don't make copies.
- **Android:** moves the photo into `Pictures/<name>/`, so it shows up as that folder in your gallery app. Android asks for permission each time an app moves a photo it didn't take, so you'll see a short system prompt on each swipe up. If you decline, the photo comes back.

## Install

- **iOS:** every push to `main` builds an unsigned IPA and publishes it as a [GitHub release](../../releases), ready for SideStore or AltStore.
- **Android:** the *Build APK* workflow uploads `SwipeClean.apk` as an artifact on each run. Download it from the [Actions](../../actions) tab and install it.

## Build it yourself

**iOS** (iOS 17+, needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

```sh
brew install xcodegen
xcodegen generate
open SwipeClean.xcodeproj
```

**Android** (Android 11+, JDK 17, Gradle 8.10):

```sh
cd android
gradle assembleDebug
# app/build/outputs/apk/debug/app-debug.apk
```

## Project layout

```
Sources/            iOS app (SwiftUI + PhotoKit), all in ContentView.swift
project.yml         XcodeGen project definition
android/            Android app (Jetpack Compose + MediaStore), all in MainActivity.kt
.github/workflows/  CI: build.yml (IPA + release), android.yml (APK)
```

## Privacy

SwipeClean has no accounts, servers or analytics. Everything happens on your phone; on iOS, Photos may download a picture from iCloud so it can be shown.
