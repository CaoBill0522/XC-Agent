"""列出界面文字的翻译键（中文原文）：tr('…') / trArgs('…') 的字面量，
以及枚举 / 常量里显示时才翻译的中文（见 DYNAMIC_FILES）。
用法：python3 tool/l10n/keys.py > keys.txt"""
import os, re, sys

CJK = re.compile(r'[一-鿿]')
CALL = re.compile(r"\b(?:tr|trArgs)\(\s*'((?:[^'\\]|\\.)*)'")
LIT = re.compile(r"'((?:[^'\\\n]|\\.)*)'")
# 这些文件里没包 tr 的中文常量（枚举名称、提示常量等）在显示时翻译。
DYNAMIC_FILES = [
    'lib/core/chat/conversation_mode.dart',
    'lib/core/chat/chat_types.dart',
    'lib/core/models/capabilities.dart',
    'lib/core/routing/model_router.dart',
    'lib/core/chat/conversation_options.dart',
    'lib/data/appearance.dart',
    'lib/features/settings/usage_page.dart',
    'lib/features/lock/app_lock.dart',
    'lib/data/tool_service.dart',
    'lib/data/chat_service.dart',
]


def unescape(s):
    return s.encode('utf8').decode('unicode_escape').encode('latin1').decode('utf8') if '\\' in s else s


def strip_comments(src):
    # 只去掉整行注释：行内的 // 可能是字符串里的网址。
    return '\n'.join(l for l in src.split('\n') if not l.lstrip().startswith('//'))


keys = []
seen = set()
def add(k):
    if k not in seen:
        seen.add(k)
        keys.append(k)

for d, _, fs in os.walk('lib'):
    for f in sorted(fs):
        p = os.path.join(d, f)
        if not f.endswith('.dart') or f.endswith('.g.dart') or p.startswith('lib/l10n/'):
            continue
        src = strip_comments(open(p, encoding='utf8').read())
        for m in CALL.finditer(src):
            add(m.group(1))
        if p in DYNAMIC_FILES:
            for line in src.split('\n'):
                if 'tr(' in line or 'trArgs(' in line:
                    continue
                for m in LIT.finditer(line):
                    if CJK.search(m.group(1)):
                        add(m.group(1))

# 厂商预设里的名称（ProviderPreset.name 显示时翻译）。
import json
for preset in json.load(open('assets/presets/providers.json', encoding='utf8'))['presets']:
    if CJK.search(preset['name']):
        add(preset['name'])

if __name__ == '__main__':
    for k in keys:
        print(k)
