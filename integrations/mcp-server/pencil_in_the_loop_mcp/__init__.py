"""Pencil-in-the-loop MCP server.

A local MCP server that writes documents into the sync folder's ``inbox/``
and reads review bundles back out of ``outbox/``, per
``docs/05-file-contracts.md``.

The folder is the only interface. There is no database and no state beyond
an optional config file recording where the sync folder lives.
"""

__version__ = "0.1.0"
