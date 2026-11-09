"""生成 XCAgent 图标（C 圆弧 + 神经网络节点组成的 X）。

浅色：白底黑图形；深色：黑底白图形。图形由 render.swift 用 CoreGraphics 绘制，
支持透明背景；只依赖 macOS 自带的 swift，不需要额外安装。
用法：python3 tool/icon/make_icons.py
"""
import json
import os
import shutil
import struct
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
BLACK, WHITE = '#000000', '#FFFFFF'

jobs = []


def job(out, size, fg, bg=None, scale=1.0, **kw):
    jobs.append({'out': os.path.join(ROOT, out), 'size': size, 'fg': fg, 'bg': bg,
                 'scale': scale, **kw})


# ── iOS：单一 1024 图标，浅色 / 深色 / 着色三种外观（iOS 18 起随系统外观切换）
ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
shutil.rmtree(os.path.join(ROOT, ios), ignore_errors=True)
job(f'{ios}/icon-light.png', 1024, BLACK, WHITE)
job(f'{ios}/icon-dark.png', 1024, WHITE, BLACK)
# 着色外观：系统按亮度上色，白色图形 + 透明背景。
job(f'{ios}/icon-tinted.png', 1024, WHITE)

# ── macOS / Windows：系统不加遮罩，图标自带圆角方块（Apple 模板 824/1024）
mac = 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
for px in (16, 32, 64, 128, 256, 512, 1024):
    job(f'{mac}/app_icon_{px}.png', px, BLACK, WHITE, 0.78, tile=True, inset=100, radius=185)
win_sizes = (16, 24, 32, 48, 64, 128, 256)
for px in win_sizes:
    job(f'build/icon_tmp/win_{px}.png', px, BLACK, WHITE, 0.86, tile=True, inset=40, radius=200)

# ── Android：旧版图标、自适应图标前景（背景为白色）、主题图标（单色）
res = 'android/app/src/main/res'
for dpi, launcher, adaptive in [('mdpi', 48, 108), ('hdpi', 72, 162), ('xhdpi', 96, 216),
                                ('xxhdpi', 144, 324), ('xxxhdpi', 192, 432)]:
    job(f'{res}/mipmap-{dpi}/ic_launcher.png', launcher, BLACK, WHITE, 0.86,
        tile=True, inset=0, radius=230)
    # 自适应图标只有中间 66% 一定可见：图形缩到 0.6。
    job(f'{res}/mipmap-{dpi}/ic_launcher_foreground.png', adaptive, BLACK, None, 0.6)
    job(f'{res}/mipmap-{dpi}/ic_launcher_monochrome.png', adaptive, WHITE, None, 0.6)

# ── 应用内（首次引导页）用的标志
job('assets/brand/logo_light.png', 512, BLACK, WHITE)
job('assets/brand/logo_dark.png', 512, WHITE, BLACK)

subprocess.run(['swift', os.path.join(HERE, 'render.swift')], input=json.dumps(jobs).encode(),
               check=True)

# iOS Contents.json
img = lambda f, app=None: {
    'filename': f, 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024',
    **({'appearances': [{'appearance': 'luminosity', 'value': app}]} if app else {}),
}
with open(os.path.join(ROOT, ios, 'Contents.json'), 'w') as f:
    json.dump({'images': [img('icon-light.png'), img('icon-dark.png', 'dark'),
                          img('icon-tinted.png', 'tinted')],
               'info': {'author': 'xcode', 'version': 1}}, f, indent=2)

# Android 自适应图标定义
os.makedirs(os.path.join(ROOT, res, 'mipmap-anydpi-v26'), exist_ok=True)
with open(os.path.join(ROOT, res, 'mipmap-anydpi-v26', 'ic_launcher.xml'), 'w') as f:
    f.write('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
''')
with open(os.path.join(ROOT, res, 'values', 'ic_launcher_background.xml'), 'w') as f:
    f.write('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#FFFFFF</color>
</resources>
''')

# Windows .ico：直接内嵌 PNG（Vista 起支持）
pngs = [open(os.path.join(ROOT, f'build/icon_tmp/win_{px}.png'), 'rb').read() for px in win_sizes]
ico = struct.pack('<HHH', 0, 1, len(win_sizes))
offset = 6 + 16 * len(win_sizes)
for px, data in zip(win_sizes, pngs):
    ico += struct.pack('<BBBBHHII', px % 256, px % 256, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
with open(os.path.join(ROOT, 'windows/runner/resources/app_icon.ico'), 'wb') as f:
    f.write(ico + b''.join(pngs))
shutil.rmtree(os.path.join(ROOT, 'build/icon_tmp'))
print('done')
