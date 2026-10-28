#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/website-preview
swiftc -swift-version 6 -framework AppKit -framework Vision -framework Translation -framework ScreenCaptureKit Sources/Translation/*.swift Sources/Screen/*.swift Sources/Screen/Pipeline/*.swift Sources/App/ShortcutStore.swift Sources/App/AppSettings.swift Sources/App/AppleGlass.swift Sources/App/PermissionGuide.swift scripts/WebsitePreview.swift -o build/website-preview/render
build/website-preview/render
cd build/website-preview
for language in en zh-hans zh-hant ja ko fr de es; do
  cwebp -quiet -lossless "docs-$language.png" -o "../../docs/assets/screen-$language.webp"
  [[ $language == en ]] || cwebp -quiet -lossless "toolbar-$language.png" -o "../../docs/assets/toolbar-$language.webp"
done
for name in toolbar-original chart-select capture-read capture-mark capture-keep capture-docs preview permission; do
  cwebp -quiet -lossless "$name.png" -o "../../docs/assets/$name.webp"
done
# Close-ups of the toolbar, cropped from the 8x renders. Rectangles are in points.
python3 -I - <<'PY'
from PIL import Image
crops = {
    'tools': ('mark', (122, 11, 300, 52)),
    'colours': ('mark', (14, 86, 336, 122)),
    'history': ('mark', (440, 86, 536, 122)),
    'direction': ('mark', (16, 54, 122, 84)),
    'text': ('mark', (314, 10, 372, 50)),
    'copied': ('kept', (422, 12, 510, 48)),
    'pin': ('kept', (367, 10, 405, 50)),
}
# The dark surface carries a faint vertical sheen; each row is shifted to one flat tone so the
# close-up sits on its tile without a visible box.
def flatten(image, tone=(38, 38, 38)):
    image = image.convert('RGBA')
    px = image.load()
    w, h = image.size
    for y in range(h):
        edge = sorted(px[x, y][:3] for x in list(range(4)) + list(range(w - 4, w)))
        base = edge[len(edge) // 2]
        shift = [tone[i] - base[i] for i in range(3)]
        for x in range(w):
            r, g, b, a = px[x, y]
            px[x, y] = (max(0, min(255, r + shift[0])), max(0, min(255, g + shift[1])), max(0, min(255, b + shift[2])), a)
    return image
for name, (source, box) in crops.items():
    for suffix in ('', '-dark'):
        image = Image.open(f'toolbar-{source}-8x{suffix}.png').crop(tuple(v * 8 for v in box))
        (flatten(image) if suffix else image).save(f'close-{name}{suffix}.png')
PY
for file in close-*.png; do
  cwebp -quiet -lossless "$file" -o "../../docs/assets/${file:r}.webp"
done
