"""One-version retirement helpers for historical Parent delivery records."""
import fcntl
import json
import os
from pathlib import Path
import uuid

REPORT_KINDS = {"report", "child_report", "delegated_report"}


def append_record(book, row):
    """Retire pending reports once; never rewrite an already settled outcome."""
    with open(book, "a+", encoding="utf-8") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.seek(0)
        previous = []
        for line in stream:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if record.get("rid") == row["rid"]:
                previous.append(record)
        if row.get("kind") in REPORT_KINDS or any(r.get("kind") in REPORT_KINDS for r in previous):
            if any(r.get("state") not in (None, "", "QUEUED") for r in previous):
                return False
            row = dict(row, state="FAILED", detail="RETIRED: Parent reports are disabled")
            if any(r.get("kind") == "delegated_report" for r in previous):
                row["kind"] = "delegated_report"
        stream.seek(0, os.SEEK_END)
        stream.write(json.dumps(row, ensure_ascii=False) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    return True


def archive(source, destination):
    """Keep the original bytes durably outside the runnable glob, without clobber."""
    source, destination = Path(source), Path(destination)
    with source.open("rb") as stream:
        os.fsync(stream.fileno())
    while True:
        try:
            os.link(source, destination)
            break
        except FileExistsError:
            destination = destination.with_name(destination.name + "." + uuid.uuid4().hex)
    fd = os.open(source.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
        source.unlink()
        os.fsync(fd)
    finally:
        os.close(fd)
    return str(destination)
