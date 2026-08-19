"""Logging: one line per event, timestamped, to stdout and to a file."""

from __future__ import annotations

import logging
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Optional

LOGGER_NAME = "pencil-watcher"
_FORMAT = "%(asctime)s %(levelname)-7s %(message)s"
_DATEFMT = "%Y-%m-%dT%H:%M:%S%z"


class _OneLine(logging.Formatter):
    """Collapse newlines so every event really is one line in the log."""

    def format(self, record: logging.LogRecord) -> str:
        text = super().format(record)
        return text.replace("\n", " \\n ")


def configure(log_path: Optional[Path], verbose: bool = False) -> logging.Logger:
    logger = logging.getLogger(LOGGER_NAME)
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    logger.handlers = []
    logger.propagate = False

    formatter = _OneLine(_FORMAT, datefmt=_DATEFMT)

    stream = logging.StreamHandler(stream=sys.stdout)
    stream.setFormatter(formatter)
    stream.setLevel(logging.DEBUG if verbose else logging.INFO)
    logger.addHandler(stream)

    if log_path is not None:
        try:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            file_handler = RotatingFileHandler(
                str(log_path), maxBytes=2_000_000, backupCount=5, encoding="utf-8"
            )
            file_handler.setFormatter(formatter)
            file_handler.setLevel(logging.DEBUG)
            logger.addHandler(file_handler)
        except OSError as exc:  # a broken log path must not stop delivery
            logger.warning("could not open log file %s: %s", log_path, exc)

    return logger


def get_logger() -> logging.Logger:
    return logging.getLogger(LOGGER_NAME)
