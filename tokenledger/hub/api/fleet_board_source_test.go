package api

import "testing"

// The list's groups (task DDBQ): one decision per row, a person's by default.
func TestBoardSource(t *testing.T) {
	cases := []struct {
		name string
		row  BoardRow
		want string
	}{
		{"nothing said is a person's", BoardRow{}, ""},
		{"⌘P's record is a person's", BoardRow{taskVia: "⌘P"}, ""},
		{"a scheduled run", BoardRow{ScheduleID: "s1"}, boardSourceSchedule},
		{"the schedule wins over a node word", BoardRow{ScheduleID: "s1", Source: boardSourceAgent}, boardSourceSchedule},
		{"the node's stamp", BoardRow{Source: boardSourceAgent}, boardSourceAgent},
		{"the node's stamp beats the record", BoardRow{Source: boardSourceAPI, taskVia: "编排"}, boardSourceAPI},
		{"a bearer worker_start", BoardRow{taskVia: "api"}, boardSourceAPI},
		{"a session's task tool", BoardRow{taskVia: "编排"}, boardSourceAgent},
		{"a record with a parent", BoardRow{taskAgent: true}, boardSourceAgent},
	}
	for _, c := range cases {
		if got := boardSource(c.row); got != c.want {
			t.Errorf("%s: boardSource = %q, want %q", c.name, got, c.want)
		}
	}
}
