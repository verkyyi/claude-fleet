// The decision sheet's fixture (issue #2832): 2026-10-09's six open asks — five on one
// ticket, one on another — plus a defaulted row and a never:money one, with the
// `groups` bin/fleet_decision.py group wrote for them (the steward keeps them in
// steward.state.json on every save). Regenerate with that function, never by hand.

export const SHEET_STATE = {
 "groups": [
  {
   "answer": "",
   "asked": "2026-10-09T14:05:00+08:00",
   "asks": [
    {
     "asked": "2026-10-09T10:05:00+08:00",
     "id": "r2139-0",
     "item": "真机演练准备：设备齐了吗？",
     "url": "https://github.com/verkyyi/claude-fleet/issues/2139#issuecomment-100"
    },
    {
     "asked": "2026-10-09T11:05:00+08:00",
     "id": "r2139-1",
     "item": "真机演练第 2 次：可以开始吗？",
     "url": "https://github.com/verkyyi/claude-fleet/issues/2139#issuecomment-101"
    },
    {
     "asked": "2026-10-09T12:05:00+08:00",
     "id": "r2139-2",
     "item": "真机演练第 3 次：可以开始吗？",
     "url": "https://github.com/verkyyi/claude-fleet/issues/2139#issuecomment-102"
    },
    {
     "asked": "2026-10-09T13:05:00+08:00",
     "id": "r2139-3",
     "item": "真机演练第 4 次：可以开始吗？",
     "url": "https://github.com/verkyyi/claude-fleet/issues/2139#issuecomment-103"
    },
    {
     "asked": "2026-10-09T14:05:00+08:00",
     "id": "r2139-4",
     "item": "真机演练第 5 次：可以开始吗？",
     "url": "https://github.com/verkyyi/claude-fleet/issues/2139#issuecomment-104"
    }
   ],
   "by": "",
   "closed_at": "",
   "default": "开始",
   "due": "2026-10-09T18:05:00+08:00",
   "due_show": "10-09 18:05",
   "from": "同一张单问了 5 次（10-09 10:05 → 10-09 14:05）",
   "gid": "r2139-4",
   "ids": [
    "r2139-0",
    "r2139-1",
    "r2139-2",
    "r2139-3",
    "r2139-4"
   ],
   "item": "真机演练第 5 次：可以开始吗？",
   "kind": "normal",
   "never": false,
   "src": "gh:verkyyi/claude-fleet#2139",
   "state": "open",
   "suggest": "开始",
   "url": "https://github.com/verkyyi/claude-fleet/issues/2139#issuecomment-104"
  },
  {
   "answer": "",
   "asked": "2026-10-09T09:30:00+08:00",
   "asks": [
    {
     "asked": "2026-10-09T09:30:00+08:00",
     "id": "r11958",
     "item": "小程序试点选哪家商户？",
     "url": "https://github.com/24haowan/24haowan-monorepo/issues/11958#issuecomment-7"
    }
   ],
   "by": "",
   "closed_at": "",
   "default": "等你",
   "due": "",
   "due_show": "—",
   "from": "",
   "gid": "r11958",
   "ids": [
    "r11958"
   ],
   "item": "小程序试点选哪家商户？",
   "kind": "normal",
   "never": false,
   "src": "gh:24haowan/24haowan-monorepo#11958",
   "state": "open",
   "suggest": "",
   "url": "https://github.com/24haowan/24haowan-monorepo/issues/11958#issuecomment-7"
  },
  {
   "answer": "不开",
   "asked": "2026-10-09T08:10:00+08:00",
   "asks": [
    {
     "asked": "2026-10-09T08:10:00+08:00",
     "id": "rnever",
     "item": "要不要开云机器？",
     "url": ""
    }
   ],
   "by": "person",
   "closed_at": "2026-10-09T12:02:00+08:00",
   "default": "等你（永不默认：花钱）",
   "due": "",
   "due_show": "—",
   "from": "",
   "gid": "rnever",
   "ids": [
    "rnever"
   ],
   "item": "要不要开云机器？",
   "kind": "never:money",
   "never": true,
   "src": "gh:o/r#6",
   "state": "defaulted",
   "suggest": "不开",
   "url": ""
  },
  {
   "answer": "",
   "asked": "2026-10-09T08:00:00+08:00",
   "asks": [
    {
     "asked": "2026-10-09T08:00:00+08:00",
     "id": "rdef",
     "item": "日志留几天？",
     "url": ""
    }
   ],
   "by": "",
   "closed_at": "2026-10-09T12:01:00+08:00",
   "default": "7 天",
   "due": "2026-10-09T12:00:00+08:00",
   "due_show": "10-09 12:00",
   "from": "",
   "gid": "rdef",
   "ids": [
    "rdef"
   ],
   "item": "日志留几天？",
   "kind": "normal",
   "never": false,
   "src": "gh:o/r#5",
   "state": "defaulted",
   "suggest": "7 天",
   "url": ""
  }
 ],
 "rows": {
  "r11958": {
   "asked": "2026-10-09T09:30:00+08:00",
   "default": "",
   "due": "",
   "id": "r11958",
   "item": "小程序试点选哪家商户？",
   "kind": "normal",
   "src": "gh:24haowan/24haowan-monorepo#11958",
   "state": "open",
   "suggest": "",
   "url": "https://github.com/24haowan/24haowan-monorepo/issues/11958#issuecomment-7",
   "v": "0"
  },
  "r2139-0": {
   "asked": "2026-10-09T10:05:00+08:00",
   "default": "开始",
   "due": "2026-10-09T14:05:00+08:00",
   "id": "r2139-0",
   "item": "真机演练准备：设备齐了吗？",
   "kind": "normal",
   "src": "gh:verkyyi/claude-fleet#2139",
   "state": "open",
   "suggest": "开始",
   "url": "https://github.com/verkyyi/claude-fleet/issues/2139#issuecomment-100",
   "v": "1"
  },
  "r2139-1": {
   "asked": "2026-10-09T11:05:00+08:00",
   "default": "开始",
   "due": "2026-10-09T15:05:00+08:00",
   "id": "r2139-1",
   "item": "真机演练第 2 次：可以开始吗？",
   "kind": "normal",
   "src": "gh:verkyyi/claude-fleet#2139",
   "state": "open",
   "suggest": "开始",
   "url": "https://github.com/verkyyi/claude-fleet/issues/2139#issuecomment-101",
   "v": "1"
  },
  "r2139-2": {
   "asked": "2026-10-09T12:05:00+08:00",
   "default": "开始",
   "due": "2026-10-09T16:05:00+08:00",
   "id": "r2139-2",
   "item": "真机演练第 3 次：可以开始吗？",
   "kind": "normal",
   "src": "gh:verkyyi/claude-fleet#2139",
   "state": "open",
   "suggest": "开始",
   "url": "https://github.com/verkyyi/claude-fleet/issues/2139#issuecomment-102",
   "v": "1"
  },
  "r2139-3": {
   "asked": "2026-10-09T13:05:00+08:00",
   "default": "开始",
   "due": "2026-10-09T17:05:00+08:00",
   "id": "r2139-3",
   "item": "真机演练第 4 次：可以开始吗？",
   "kind": "normal",
   "src": "gh:verkyyi/claude-fleet#2139",
   "state": "open",
   "suggest": "开始",
   "url": "https://github.com/verkyyi/claude-fleet/issues/2139#issuecomment-103",
   "v": "1"
  },
  "r2139-4": {
   "asked": "2026-10-09T14:05:00+08:00",
   "default": "开始",
   "due": "2026-10-09T18:05:00+08:00",
   "id": "r2139-4",
   "item": "真机演练第 5 次：可以开始吗？",
   "kind": "normal",
   "src": "gh:verkyyi/claude-fleet#2139",
   "state": "open",
   "suggest": "开始",
   "url": "https://github.com/verkyyi/claude-fleet/issues/2139#issuecomment-104",
   "v": "1"
  },
  "rdef": {
   "asked": "2026-10-09T08:00:00+08:00",
   "closed_at": "2026-10-09T12:01:00+08:00",
   "default": "7 天",
   "due": "2026-10-09T12:00:00+08:00",
   "id": "rdef",
   "item": "日志留几天？",
   "kind": "normal",
   "src": "gh:o/r#5",
   "state": "defaulted",
   "suggest": "7 天",
   "v": "1"
  },
  "rnever": {
   "answer": "不开",
   "asked": "2026-10-09T08:10:00+08:00",
   "by": "person",
   "closed_at": "2026-10-09T12:02:00+08:00",
   "default": "",
   "due": "",
   "id": "rnever",
   "item": "要不要开云机器？",
   "kind": "never:money",
   "src": "gh:o/r#6",
   "state": "defaulted",
   "suggest": "不开",
   "v": "1"
  }
 },
 "sheet": {
  "at": "2026-10-09T14:28:00+08:00",
  "id": "s1",
  "rows": [
   "r2139-0",
   "r2139-1",
   "r2139-2",
   "r2139-3",
   "r2139-4",
   "r11958"
  ],
  "sent": true,
  "where": "x"
 },
 "v": 1
}
