# Third party notices

Zumbo reads from MIT-licensed donor projects kept in `references/`. Code that
was lifted or closely followed is listed here, and the same list goes on the
Acknowledgements screen in Settings.

## OpenDictation

MIT License. Copyright (c) 2025 Kenny.

Used for:

- Hardware notch measurement: `NSScreen.safeAreaInsets.top` together with
  `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` to get the exact notch
  rectangle (`Sources/Notch/NotchGeometry.swift`). OpenDictation credits
  Lakr233/NotchDrop for the pattern.
- Overlay panel configuration: borderless nonactivating `NSPanel`, clear
  background, no shadow, `canJoinAllSpaces` + `fullScreenAuxiliary` +
  `stationary` collection behavior, `canBecomeKey` / `canBecomeMain` returning
  false so the panel never steals focus (`Sources/Notch/NotchPanel.swift`).
- Waveform structure: a `TimelineView(.animation)` bar meter whose amplitude is
  the microphone level with a small idle floor, so silence still breathes
  (`Sources/Notch/WaveformBarsView.swift`).

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions: the above copyright notice and this
permission notice shall be included in all copies or substantial portions of the
Software.

## OpenSuperWhisper

MIT License. Kept in `references/` for the capture and paste pipeline. Nothing
from it is in the app shell yet.

## Not used

boring.notch is GPL and was removed from `references/`. No code, path data or
radii from it are in Zumbo. The notch shape in `Sources/Notch/NotchShape.swift`
is written from the geometry description in `../dictation-spike/NOTES.md`.

## Sparkle

MIT License. Copyright (c) 2006-2013 Andy Matuschak, copyright (c) 2009-2013
Elgato Systems GmbH, copyright (c) 2011-2014 Kornel Lesinski, copyright (c)
2015-2017 Mayur Pawashe, copyright (c) 2014 C.W. Betts, copyright (c) 2014
Petroules Corporation, copyright (c) 2014 Big Nerd Ranch.

Used as a dependency, not lifted: `Sparkle.framework` is embedded in the app
bundle and drives updates. Zumbo supplies its own `SPUUserDriver`
(`Sources/App/UpdateDriver.swift`) so every update step is drawn in the notch
instead of Sparkle's own windows. Sparkle also vendors bsdiff (BSD licence)
and its own copy of Ed25519/libb2 for update signature verification.
