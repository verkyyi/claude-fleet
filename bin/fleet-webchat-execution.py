#!/usr/bin/env python3
"""Old SDK handoff cannot become a second executor of a controlled Task."""
import sys

from fleet_task_execution import FenceRefused, check_session


def main():
    try:
        if len(sys.argv) != 2:
            raise FenceRefused("an immutable session FID is required")
        if check_session(sys.argv[1]) is not None:
            raise FenceRefused("Task execution belongs to its native session")
    except (FenceRefused, OSError, ValueError):
        print("请在统一会话中继续此任务；旧 WebChat 不能启动第二个执行会话。", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
