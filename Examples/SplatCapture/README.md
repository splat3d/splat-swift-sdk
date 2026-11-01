# SplatCapture Example App

The reference app for the [Splat3D](../../) SDK. It records video with ARKit
LiDAR poses, uploads it to the Splat3D API for 3D Gaussian splat processing,
follows the job, and shows the result natively with
[SplatKit](https://github.com/Xget7/splatkit-ios). It covers the whole
lifecycle (capture, upload, progress, thumbnail, view, delete) and every way
a run can stop, including resuming after the app is killed without paying
twice.

## Setup

1. Open `SplatCapture.xcodeproj` in Xcode 26 or later. The app uses iOS 26's
   Liquid Glass, which only the iOS 26 SDK compiles; it still runs on iOS 17
2. The project references the Splat3D SDK as a local SPM package (two
   directories up), and SplatKit `0.1.0-beta.1` from GitHub, which downloads a
   prebuilt XCFramework. Xcode resolves both automatically; the first build
   needs a network connection.
3. Select your physical iPhone as the run destination and hit **Run**. The
   app asks you to sign in on splat-3d.com; there is no key to set up.

## Signing in

The app holds no API key, and none is compiled into it. On first launch you
sign in or create an account on splat-3d.com in the system browser, and the
app receives a key made for that device, which you can revoke in the
dashboard under Developer. It follows RFC 8252: the system browser, an
authorization code, and PKCE (S256). The callback is an https link on the
website that iOS checks against the site's `webcredentials` association, so
no other app can catch the code. The app keeps the key in the Keychain, and
a reinstall starts signed out.

```
SplatCapture                          splat-3d.com                       api.splat-3d.com
 verifier, challenge = S256(verifier), state, device_id
 ── /connect/app?client_id&code_challenge&state&device_id ─▶ sign in, Allow
 ◀── https://splat-3d.com/connect/app/callback?code&state ──
 check state
 ── POST /v1/app/token {code, code_verifier} ─────────────────────────▶ api key
 Keychain ← key;  GET /v1/app/account, getUsage()
 sign out ── DELETE /v1/app/key ───────────────────────────────────────▶ revoked
```

The three `/v1/app/*` routes are for this app only and aren't in the public
API spec.

**Staging.** Debug builds can use the staging site and API: launch with
`-SplatEnvironment staging` (in the scheme's arguments). The choice is saved,
so a launch from the Home Screen keeps it; `-SplatEnvironment prod` switches
back. Release builds always use production. Staging sign-in needs the staging
site's `webcredentials` association, which the entitlements list.

## Rules before capture

After signing in, the start screen shows what the account allows, from
`GET /v1/app/account` and the SDK's `getUsage()`: the credit balance, what
each preset costs, and the scenes used this month. Start stays off when the
balance is below the preset's cost or the month's scene limit is used up, and
a warning shows when scenes already fill the plan's processing slots (a scan
still starts; its launch waits for a free slot). These checks only say early
what the server would say late: it enforces every rule, and when the account
can't be read, nothing blocks. `CaptureRules.swift` holds them.

**Account** (top left) shows the email, plan, credits and scenes this month,
and has Sign out, which revokes the device's key and discards saved scans, and
Delete account, which opens splat-3d.com (deletion takes up to 30 days).

## Purchase links

Links to buy credits (Add credits, Open billing, Manage on splat-3d.com) show
only when the App Store storefront is the United States; elsewhere the app
says what is missing and nothing more. This follows the App Store rule that
lets US apps link out to the web. It does not make buying credits on the web
safe from App Review everywhere (guideline 3.1.1), so the link rule is a
reason for the gating, not a guarantee.

## Device Requirements

- **iPhone 12 Pro or newer** (requires LiDAR scanner)
- iPad Pro with LiDAR also works for capture; viewing in 3D needs an M1 iPad Pro
  or newer (see below)
- iOS 17.4+. Sign-in's https callback needs it; the Splat3D SDK itself still supports iOS 16
- Camera and motion permissions are requested on first launch

The app requires only ARKit to install. On a device without LiDAR, the start
screen says capture needs it and keeps **Start capture** off. Scenes and the
viewer still work.

**View in 3D** draws with Metal on Apple GPU family 7: A14, M1 or newer, on a
physical device. The app goes by SplatKit's `SplatMetalView.isAvailable`,
which is also false when SplatKit's Metal setup fails (shader compile, command
queue or buffers). Where it's false, as in the Simulator, the app downloads
the scene and says it can't draw it.

## Usage

1. Pick a preset. **Fast** is the default: the quickest and cheapest, good for
   testing. The choice is remembered. The start screen also checks LiDAR,
   camera access and what the account allows.
2. Tap **Start capture**. The camera view opens with a blue mesh overlay
   showing surfaces detected by the LiDAR scanner
3. Slowly walk around the scene you want to capture, for at least 30
   seconds: the API refuses a shorter video with a 422 `source_unusable`,
   before charging anything
4. Watch the **pose** and **frame** counters in the top-right, and the
   **tracking** status above the stop button
5. Tap **Stop and upload** when done, or **Cancel** to delete the scan
   without uploading it. Before 30 seconds, Stop asks first and shows the
   time recorded: **Keep recording**, or **Discard scan**, which deletes it
   as Cancel does. The minimum is `CaptureLength.minimum` in
   `CaptureModel.swift`
6. The app saves the capture, uploads the video and ARKit poses, launches
   processing and follows it step by step: upload (with bytes sent), launch,
   process (the stage in words, and the percent), and the scene's thumbnail
   as soon as the pipeline makes one
7. When done, the screen shows the preset and the training time, and **View
   in 3D** explores the scene in the app. **Open on splat-3d.com** (the web
   viewer) and **Delete scene** are in the **More** menu (…) at the top right

**Scenes** (top right) lists the account's latest scenes with their status
and preset. A complete one opens in 3D. Swipe or long-press a row to delete
it.

## When a run stops

The app reads every error from `createAndProcess` the way the SDK's README
describes ("Continuing after a failure"), and never ends in a spinner or a
raw error:

| What happened | What the app shows | Next |
|---|---|---|
| Network lost mid-upload or mid-launch | **Connection lost**, what was charged (nothing, or at most once). Resume is off while offline | Resumes by itself when the network is back, or **Resume**: `client.resume(interruption)` |
| App left mid-run | It asks iOS for background time; when that runs out, the run pauses | Resumes by itself when the app is back |
| App killed mid-run | On the next launch, the run picks up | Resumes by itself: `client.resume(sceneID:preset:arkitPoses:lidarPoints:)` with the saved capture |
| App killed mid-upload | Resume gets `source_missing`, before anything is charged | Uploads by itself to a new scene from the saved capture; the old one is deleted |
| Not enough credits | **Not enough credits**, worded from the error code | **Add credits** (US storefront only), then **Resume** |
| Too many scenes processing | The plan's limit, worded from the error code | **Resume** later |
| Monthly limit reached | Worded from the error code | **Open billing** (US storefront only), or **Resume** next month |
| The key is rejected (401) | **Signed out** | Sign in again; the capture waits and resumes |
| Job failed or cancelled on the server | **Processing failed** (refunded) or **Scene cancelled** | **Process again** (a new, charged scene) or discard |
| The API can't use the upload (`source_unusable`) | **The server can't use this capture**, nothing charged | **New capture**, which also deletes the scene |
| Unknown status | The step reads **Working** | Keeps waiting |
| No LiDAR, camera off | Said on the start screen, with **Open Settings** for the camera | Scenes still work |

So that a killed app can resume, `CaptureStore.swift` keeps the capture in
Application Support (out of iCloud backups) from before the scene is created
until it completes or you discard it: the video, the poses and LiDAR points
the launch resends, the preset, and the scene ID from `onSceneCreated`. A run
that failed comes back on its failed screen after a relaunch, with the same
next step.

### Previewing states

Debug builds take a `-SplatPreviewState` launch argument that shows one
screen in a fixed state, with made-up data and no API client, so every state
can be checked on the Simulator, which can't run ARKit. `PreviewHarness.swift`
lists them:

```sh
xcrun simctl launch booted com.splat3d.SplatCapture -SplatPreviewState paused-credits
```

A state ending in `-accessibility`, such as `home-accessibility`, shows it at
the largest Dynamic Type size. `scanning-bright` and
`viewer-orbit-bright` put a bright room behind the overlays instead of the
Simulator's black, to check that the glass stays legible over a light
picture. `viewer-info` opens the info sheet on a scene with every detail,
`viewer-info-legacy` on one from an API before 1.5.0, and
`viewer-info-full` shows the sheet's whole list.

Release builds don't contain it.

## Viewing in 3D

The viewer downloads the scene's SPZ, the compressed format SplatKit reads,
showing the bytes as they arrive, then hands the file to SplatKit.

The controls are in the toolbar at the bottom:

- **Orbit** (default): drag to circle the scene, pinch to move in or out
- **Look**: drag to turn on the spot; hold the arrows to move forward or back
- **Flip**: turns the picture upside down, for a scene that comes out that
  way, see below
- **Reset** (the target icon): back to the starting view
- In Debug builds, the line at the top is SplatKit's frame rate and splats
  drawn

**Info** (top right) opens the scene's details in a sheet. First, as on
the Ready screen: the preset, training and total processing time, and the
splat count. Then the quality metrics, the training PSNR with the word
splat-3d.com gives it (Excellent, Good, Fair or Poor); the size of each
model file, the one on screen marked **Viewing**; and the scene's ID, with
a button that copies it, when it was created and finished processing, and
whether it is public. API 1.5.0 added the preset, the times, the sizes and
the training PSNR, and 1.3.0 the holdout metrics. An older API doesn't
send them, and the sheet leaves out what it doesn't have.

What can go wrong, and what the app says:

- **This scene has no SPZ**: the API answers 404 for a scene without one.
  Scenes processed before SPZ export, or whose SPZ conversion failed, have none.
- **SPZ download not available on this server yet**: the API rejects
  `format=spz` (a 400 naming `format`) until it serves SPZ downloads.

Asking again would bring the same answer for these two, so instead of **Try
again** the screen offers **Open on splat-3d.com**, whose viewer needs no SPZ.
- **SplatKit couldn't load this scene**: SplatKit refused the file. Its
  message follows. "SPZ payload exceeds the decoded size ceiling" means the
  scene is too big for SplatKit: it accepts at most 768 MiB unpacked, and
  counts a Splat3D SPZ (version 4) at 236 B per splat with degree-3 spherical
  harmonics, the pipeline's default. That's about 3.4M splats; **Recent
  Scenes** shows each scene's count.

### Which way is up

SplatKit has no orientation setting: it reads every SPZ as World Labs files
are laid out, +Y down, and turns it half a turn about X. Splat3D's pipeline
turns scenes so +Y is up, the convention of PlayCanvas, three.js and
SuperSplat, and writes the SPZ with those coordinates as they are. Those would
come out upside down, so the viewer rotates SplatKit's picture half a turn on
screen. Touches turn with it, so dragging still follows the picture. **Flip**
turns it half a turn again, which shows SplatKit's own orientation.

The pipeline doesn't get every scene upright yet. ARKit scenes processed before
it took up from ARKit's gravity direction can be about 90° off, which **Flip**
can't correct. At least one video uploaded without ARKit poses still shows
upside down until you tap **Flip**.

## How It Works

This app demonstrates these Splat3D APIs:

- **`SplatScanner`** — wraps ARKit + AVAssetWriter to capture video and camera
  poses simultaneously. Exposes the `ARSession` so you can show a live camera
  preview.
- **`SplatClient.createAndProcess()`** — the high-level convenience method that
  creates a scene, uploads the video, triggers processing, and polls until
  complete. Its `onSceneCreated` callback saves the scene ID; its progress
  callback drives the steps.
- **`SplatClient.resume(_:)`** and **`resume(sceneID:preset:arkitPoses:lidarPoints:)`**
  — continue an interrupted run in the same session, or after a relaunch,
  without paying twice. `CaptureModel.swift` reads each error into paused
  (Resume) or failed (what next).
- **`ARKitPose`** — the pose format sent to the API. Each pose includes the 4x4
  camera transform, 3x3 intrinsics, image dimensions, and a filename.
- **`SplatClient.listScenePage()`** — the Scenes list.
- **`SplatClient.getSceneThumbnail(id:)`** — the list's thumbnails, and the
  progress and complete screens' preview. It sends the API key, which a
  private scene's thumbnail needs, so `AsyncImage` can't load them. The list
  keeps the decoded images in memory while it is open.
- **`SplatClient.deleteScene(id:)`** — Delete, on the complete screen and in
  the list.
- **`SplatClient.downloadScene(id:format:)`** — fetches the SPZ with
  `format: .spz`. It gives the client a `URLSession` whose delegate watches
  the download's bytes, as the capture's client does for the upload.

Key sections are marked with `// MARK: - Splat3D Integration` comments:

| File | What it holds |
|---|---|
| `AccountSession.swift`, `AppAPI.swift`, `PKCE.swift`, `Keychain.swift`, `AppEnvironment.swift` | Sign-in, the key, the account calls, and where the app points |
| `SignInView.swift`, `AccountView.swift`, `CaptureRules.swift` | The sign-in and account screens, and the rules before capture |
| `CaptureModel.swift` | The run: scan, upload, resume, the error reading, background time |
| `CaptureStore.swift` | The capture on disk, for resuming after a relaunch |
| `ContentView.swift` | Start screen, camera view, navigation |
| `RunViews.swift` | Progress, paused, failed and complete screens |
| `RecentScenesView.swift` | Scenes: list, thumbnails, delete |
| `SceneViewer.swift`, `SplatWorldView.swift` | The 3D viewer |
| `SceneInfo.swift` | The viewer's info sheet, and how scene facts are written |
| `Theme.swift` | Splat3D's look: colors, type, cards, glass buttons and surfaces, the mark |
| `PreviewHarness.swift` | Debug only: every state, with made-up data |

## Design

On iOS 26 the app uses Liquid Glass where Apple puts it: on the layer that
floats over content. A screen's actions are pinned at its foot, over the
content, which scrolls under them with the scroll edge effect: the primary
action is a glass capsule filled with Splat3D's blue accent, Rinse, and the
others are glass with a plain label, or red for a destructive one. Rarer
actions, such as opening the web viewer or deleting, are in the toolbar's
**More** menu. The overlays on the camera, and the viewer's toolbar, are
glass too. Content is an inset grouped list, as in Settings, so margins and
corners are the system's; a button inside it is a bordered capsule, never
glass. A status is a colored dot with text. On iOS 17 to 25 the same screens
use bordered capsule buttons on a bar at the foot, and material overlays.
The app follows the system's light or dark appearance, Increase Contrast
and Dynamic Type.

Headlines are set in Hanken Grotesk, and scene IDs, numbers and sizes in
Martian Mono at 87.5% width; both are bundled in `Fonts/`. Everything else is
the system font. `Theme.swift` holds the switch between glass and the
fallback, so the views never check the OS version. The app icon is mark G·5
on ink, drawn in the app by `Mark` in `Theme.swift`, which also fills the
complete screen's picture until the thumbnail arrives.

## Release builds

The version and build number are in `SplatCapture.xcconfig`; raise
`CURRENT_PROJECT_VERSION` for every TestFlight upload. Release builds leave
out the state previews and the viewer's frame-rate line. The Info.plist
declares `ITSAppUsesNonExemptEncryption = NO`: the app uses only the HTTPS
that iOS provides. `PrivacyInfo.xcprivacy` declares the data the app
collects and the required-reason APIs it uses.

Before archiving:

- [ ] The association file is reachable through Apple's CDN:
      `https://app-site-association.cdn-apple.com/a/v1/splat-3d.com` lists the
      app under `webcredentials`. Sign-in fails without it
- [ ] `CURRENT_PROJECT_VERSION` is higher than the last upload
- [ ] The Release `Info.plist` has no `SplatAPIKey` (CI checks this, and that
      the privacy manifest and entitlements ship)

## Credits

3D viewing uses [SplatKit](https://github.com/Xget7/splatkit-ios), copyright
(c) 2026 Juan Ignacio Andrade, under the MIT License. Its XCFramework carries
the notices of what it bundles (SPZ, Zstandard, JSON for Modern C++ and
splat-transform) in `SplatKitCore.xcframework/Notices`.

[Hanken Grotesk](https://github.com/marcologous/hanken-grotesk), copyright
2021 The Hanken Grotesk Project Authors, and
[Martian Mono](https://github.com/evilmartians/mono), copyright 2021 The
Martian Mono Project Authors, are under the SIL Open Font License 1.1. The
fonts are the unmodified variable files from Google Fonts, renamed; their
licenses are in `Fonts/` and ship in the app.
