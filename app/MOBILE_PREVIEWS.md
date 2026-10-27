# Mobile previews and notification privacy

This change is presentation and authenticated viewing only. It does not send messages, approve drafts, mutate cached assistant text, or change dictation.

## Draft cards

Recognized EMAIL/WHATSAPP/IMESSAGE/SMS DRAFT panels inside text fences become wrapping cards. Canonical panel.py two-column headers are rendered as labels and values. Unknown/mixed panel structure falls back to the entire original text, soft-wrapped. Copy always uses the complete original fenced-block contents, including panel borders. Ordinary code stays horizontally scrollable. Selection remains available in completed assistant messages.

## Artifact wire and lifetime

The app sends `artifact_open {id,url}` only for a tapped file URL, then sequential `artifact_chunk {id,transfer_id,offset}`, followed by `artifact_close {id,transfer_id}`. The extension authorizes the URL from authoritative active-branch assistant history. Client types match backend `src/artifacts.ts`; notification v2 bytes match `src/notifications.ts` in the backend worker tree.

The app captures channel, canonical peer and room at tap, rejects stale operations after switching away (even if switched back), requires explicit source room at the transport boundary, correlates request IDs, caps files at 20 MiB and raw chunks at 192 KiB, validates offsets/eof and whole-file SHA-256, and only then passes bytes to native code. One operation at a time. Cancel, timeout, denial and hash failure never fall back to opening a desktop URL. A cancelled open that has not received a handle relies on the backend's bounded handle TTL.

Native code accepts bytes plus an allowlisted extension, never a URL or arbitrary path. iOS Quick Look uses a random filename under an app-owned temporary directory, complete file protection and backup exclusion. Android uses native PdfRenderer and ImageView in an app-private dialog, private cache files, bounded image raster sizes and a secure window. Both clean up on dismissal and after five minutes, and remove abandoned cache files on initialization. Android GIF/WebP images are static previews. Inline image bubbles use an in-app pinch-to-zoom viewer without fetching anything.

Allowed formats are PDF, PNG, JPEG, GIF and WebP. SVG, HTML, documents, archives, text, HEIC, AVIF, BMP and TIFF are unsupported. A corrupt/encrypted PDF or a format unavailable in the OS viewer fails honestly. Quick Look's WebP capability is OS-dependent.

## Notification grants

`Show question previews` defaults off. Enabling it atomically enables pane names; disabling pane names disables question previews. Existing category choices and v1 signature behavior remain intact. Absence of `show_question_preview` signs v1; explicit false or true signs v2 using the exact ordered array in the shared brief. Normal app registrations omit the preview field until opted in, preserving v1 compatibility with older Mac extensions. Opting out sends v1 again; the relay resets preview permission to false. Explicit-false v2 remains supported by the protocol. Settings explain lock-screen visibility and best-effort sensitive-text filtering; credential notifications remain generic in backend policy.

## Fonts

All four embedded SF-Mono OTF assets and their pubspec declarations are removed. The app requests the OS Menlo family by name, with Courier/monospace fallbacks through the theme. No Apple font bytes are downloaded or shipped. The existing sizes, colors and mono treatment remain. Test screenshots load system Menlo from `/System/Library/Fonts/Menlo.ttc` in test-only code, outside the application asset bundle. Existing voice screenshot tests may also load system SF Pro solely in the test process.

The unsigned Runner.app audit found 30 remaining fonts, all existing package fonts (MaterialIcons, Lucide, JetBrainsMono, KaTeX and CupertinoIcons), and no Apple font assets. Test rendering demonstrates Menlo; real-device Flutter font resolution still needs release QA.

## Verification

- `flutter analyze --no-pub`: zero issues.
- `flutter test --no-pub`: 654 passing tests.
- `flutter build ios --no-codesign --no-pub`: passed, 59.4 MB Runner.app.
- `flutter build apk --debug`: unable to run because this Mac has no Android SDK. Android native source therefore remains compile/device-unverified.
- `RP_REVIEW_DIR=/tmp/rp-mobile-previews/screenshots flutter test --no-pub test/ui/chat/mobile_preview_test.dart`: synthetic 320/390/440 screenshots and image-zoom test.
- Artifact repository tests cover valid PDF and multi-chunk transfer, unknown correlation, wrong transfer/offset/eof, malformed/oversized chunks and metadata, corrupt hash, pane switch away/back, cancellation, timeout, backend denial and concurrent-open rejection.
- Link UI tests cover paired PDF success, rejection and cancel without browser fallback. Grant tests cover unchanged v1, explicit-false/true v2 and private preference migration.

Evidence is under `/tmp/rp-mobile-previews/`: `app-analyze.log`, `app-tests.log`, `app-ios-build.log`, `app-android-build.log`, `font-audit.json` and `screenshots/draft-{320,390,440}.png`.

No deployment, installation, TestFlight upload, external send or real-device test was performed. Main owns independent review, integration, signed IPA font inspection, actual APNs lock-screen validation and real paired-device/native-viewer testing. Plugin warnings about future Swift Package Manager support and simulator arm64 support are existing build limitations, not introduced dependencies.
