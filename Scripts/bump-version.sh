#!/bin/bash
# Podnosi numer buildu o 1 (aplikacja, rozszerzenia, helper) oraz wersję manifestu Safari.
cd "$(dirname "$0")/.."
P=MacAdBlock.xcodeproj/project.pbxproj
python3 - "$P" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'CURRENT_PROJECT_VERSION = (\d+);',lambda m:f'CURRENT_PROJECT_VERSION = {int(m.group(1))+1};',s)
open(p,'w').write(s)
PY
M=Sources/SafariWebExtension/Resources/manifest.json
python3 - "$M" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'"version": "0\.1\.(\d+)"',lambda m:f'"version": "0.1.{int(m.group(1))+1}"',s)
open(p,'w').write(s)
PY
grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' $P | sort | uniq -c; grep '"version"' $M
