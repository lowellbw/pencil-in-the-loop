"""The relay: the same sync root, reachable over HTTP.

Storage is a directory in the `docs/05-file-contracts.md` layout, so `core.py`
runs against it unchanged and the files on disk *are* the wire format. The
SQLite index beside it is disposable — it exists to answer "what changed since
cursor N" cheaply, and `reindex()` rebuilds all of it by walking the two
directories.
"""
