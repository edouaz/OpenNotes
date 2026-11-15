# OpenNotes identity and app icon

OpenNotes uses a small smiling open notebook: white paper, a blue cover and a quiet navy expression. The same silhouette is used on the website and in the app icon. There is no text inside the icon and no baked-in rounded mask; iOS applies its own icon shape.

## Shared visual language

The public tagline is **A little notebook. Room for every idea.** Keep the voice simple, friendly and specific to writing. Describe the current release as a public preview; do not imply App Store availability or verified hardware performance.

- **Blue:** `#3979E8`, the notebook-cover accent. Use the deeper `#245FE8` for small website text and filled buttons to keep readable contrast. White paper and quiet navy `#172B50` anchor the mascot. Website text uses `#142440` on a paper surface `#FAFBF8`; dark mode uses navy surfaces and a lighter blue for contrast.
- **Type:** native system sans-serif for navigation and body text; Iowan Old Style / Palatino / Georgia for the website’s editorial hero. Keep text selectable and avoid external font downloads.
- **Layout:** generous space, a faint dotted-paper surface, thin rules and restrained corners. Use the same icon, release name and screenshots in the README, website and release.
- **Images:** show actual app captures, with synthetic notebooks. Keep the interface intact. Label a GIF assembled from stills as a screenshot slideshow. No generated app screens or invented performance claims.
- **Motion:** keep the tour behind an explicit disclosure and hide animation when reduced motion is requested. Static screenshots always remain available.

## Source and reproducible exports

The mascot was generated with the built-in ImageGen tool for this project. The original transparent source is `docs/assets/mascot-source.png`. The website uses the smaller `mascot.png` and `icon-light.png`, `icon-dark.png`, and `icon-tinted.png` exports. The editable generation prompt is recorded below. PNG exports are source artwork, not screenshots or a claim of an installed app.

Rebuild the exports on macOS with Xcode's command-line tools:

```sh
swift scripts/build-icons.swift
```

The script uses only Apple's system frameworks. It keeps the source artwork unchanged, composites the app icon on light and dark surfaces, and creates a grayscale tinted variant. The app's native asset catalog is `OpenNotes/Resources/Assets.xcassets/AppIcon.appiconset`. The 1024 × 1024 app icon files are opaque RGB PNGs. The website mascot retains transparency.

## Native appearances and compatibility

The app supplies Apple's **Any**, **Dark**, and **Tinted** icon variants through its asset catalog. Newer iOS versions select the appropriate appearance; older releases use the default artwork and the icon sizes Xcode compiles for them. The minimum deployment target remains iOS 16.

These are native app-icon appearance assets, not a custom layered Liquid Glass composition. Apple also offers Icon Composer for layered icons and clear appearances. Asset catalogs keep this prototype compatible with older iOS releases without requiring an Icon Composer project. The system may apply its own treatment for appearances not explicitly supplied.

The tinted source is grayscale so the system can apply the user's chosen tint while keeping the notebook recognizable. The default and dark versions retain the same geometry and expression. No alternate-icon selection feature or version-specific mascot is added.

See Apple's [asset catalog configuration](https://developer.apple.com/documentation/xcode/configuring-your-app-icon), [app icon design guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons), and [Icon Composer documentation](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).

## ImageGen prompt

> Use case: logo-brand. Create one final OpenNotes brand mascot mark, no text, no letters, no surrounding app-icon tile. A tiny gently smiling open notebook as a sophisticated friendly iOS app identity, subtle cute not childish: two softly rounded white paper pages forming one open book silhouette, a crisp luminous medium blue cover/spine wrapping the left outer edge and bottom, one small folded upper-right corner in pale blue, two small dark navy oval eyes and a very small curved smile placed low across the center pages. Balanced thoughtful custom silhouette, approachable and memorable, clean almost-vector geometry, very subtle material depth, no heavy outlines, no appendages, no sparkles, no pen, no decorative objects. Compact silhouette centered and occupying about 78 percent of a square transparent canvas, generous even space around it. White #FFFFFF, blue #3979E8, navy #172B50 only with subtle tonal variations. Legible at 32 pixels and in a monochrome version. High-quality restrained Apple-native icon visual language, not a mockup, no background, actual transparent alpha.

## Validation boundaries

Check the icon on the Home Screen at small sizes in light, dark and tinted appearances. Simulator and build validation do not establish physical-device rendering, App Store approval or signed installation. The unsigned IPA still requires your own signing and provisioning.
