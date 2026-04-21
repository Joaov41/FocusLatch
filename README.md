# Focus Latch

Focus Latch is a small macOS menu bar utility with two trackpad actions: lock focus on the current app, or pin a live preview of the current window.

## How it works

- Trigger a three-finger tap on the trackpad to lock the current app in focus.
- Trigger another three-finger tap to unlock focus.
- Trigger a three-finger press-and-hold on the trackpad to pin the current frontmost window.
- Trigger another three-finger press-and-hold to unpin it.
- The pinned window stays visible in a floating panel while you use other apps.
- Use the menu bar `Launch on Login` toggle if you want Focus Latch to start automatically when you sign in.

## Build

```bash
swift build
./scripts/build-app.sh
```

The packaged app bundle is created at `dist/FocusLatch.app`.

## Notes

- macOS may ask for Screen Recording permission so the app can capture other windows.
- The three-finger gestures are detected through the private `MultitouchSupport` framework, which makes this a personal utility rather than something suitable for App Store distribution.
- This is a visual pinned preview, not true control of another app's real window layer.
