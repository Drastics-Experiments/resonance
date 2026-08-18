from pathlib import Path

path = Path("windows/test/core.test.js")
source = path.read_text(encoding="utf-8")
old = '  assert.match(syncSource, /return \\{ catalog, downloaded, replacedTrackIDs, failed \\}/);\n'
new = (
    '  assert.match(syncSource, /return \\{ catalog, \\.\\.\\.completedBatchResult\\(\\) \\}/);\n'
    '  assert.match(syncSource, /return \\{ catalog, \\.\\.\\.completedBatchResult\\(\\), cancelled: true \\}/);\n'
)
if old in source:
    path.write_text(source.replace(old, new, 1), encoding="utf-8")
elif new not in source:
    raise RuntimeError("server sync result assertion was not recognized")
