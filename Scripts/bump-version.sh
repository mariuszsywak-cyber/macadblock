#!/bin/bash
# Podnosi numer buildu o 1 (aplikacja, rozszerzenia, helper) i zapisuje wersję manifestu
# Safari tak, żeby zawsze była równa wersji aplikacji (MARKETING_VERSION.CURRENT_PROJECT_VERSION),
# żeby wtyczka w Safari nigdy nie pokazywała innego numeru niż sama aplikacja.
cd "$(dirname "$0")/.."
P=MacAdBlock.xcodeproj/project.pbxproj
python3 - "$P" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'CURRENT_PROJECT_VERSION = (\d+);',lambda m:f'CURRENT_PROJECT_VERSION = {int(m.group(1))+1};',s)
open(p,'w').write(s)
PY
M=Sources/SafariWebExtension/Resources/manifest.json
python3 - "$P" "$M" <<'PY'
import re,sys
p, m = sys.argv[1], sys.argv[2]
s = open(p).read()
build = re.search(r'CURRENT_PROJECT_VERSION = (\d+);', s).group(1)
marketing = re.search(r'MARKETING_VERSION = ([\d.]+);', s).group(1)
version = f"{marketing}.{build}"
ms = open(m).read()
ms = re.sub(r'"version": "[^"]*"', f'"version": "{version}"', ms, count=1)
open(m, 'w').write(ms)
print("manifest version ->", version)
PY
grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' $P | sort | uniq -c; grep '"version"' $M
