"""Release notes for a version: its CHANGELOG.md section, or the commits since the previous release."""
import re
import subprocess
import sys

version, previous = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")

with open("CHANGELOG.md", encoding="utf-8") as f:
    changelog = f.read()

match = re.search(rf"^## {re.escape(version)}\b[^\n]*\n(.*?)(?=^## |\Z)", changelog, re.S | re.M)
if match and match.group(1).strip():
    print(match.group(1).strip())
else:
    rng = f"{previous}..HEAD" if previous else "HEAD"
    log = subprocess.run(["git", "log", "--no-merges", "--pretty=format:- %s", rng], capture_output=True, text=True).stdout
    print("### Changes\n" + (log.strip() or "- Maintenance update"))

print("\n---\nInstalled copies update automatically. New installs: open the disk image and drag Lirica into "
      "Applications.")
