"""Pencil-in-the-loop Mac-side outbox watcher.

Watches ``<sync root>/outbox/`` for finished review bundles and delivers each one
back into the conversation the reviewed document came from.

Stdlib only. Python 3.9+.
"""

__version__ = "0.1.0"
