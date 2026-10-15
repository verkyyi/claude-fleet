package control

import "encoding/json"

// ChatOutcome is the existing trial refund rule, shared by the HTTP proxy and
// the direct node adapter. A cancelled reader alone is never a failed turn.
type ChatOutcome struct {
	line          []byte
	reply, failed bool
}

func (o *ChatOutcome) Feed(b []byte) {
	for _, c := range b {
		if c == '\n' {
			o.frame()
			continue
		}
		if len(o.line) < 64<<10 {
			o.line = append(o.line, c)
		} else {
			o.reply = true
		}
	}
}
func (o *ChatOutcome) frame() {
	var f struct {
		T string `json:"t"`
	}
	if json.Unmarshal(o.line, &f) == nil {
		switch f.T {
		case "text", "tool", "tool_result", "ask", "done":
			o.reply = true
		case "error":
			if !o.reply {
				o.failed = true
			}
		}
	}
	o.line = o.line[:0]
}
func (o *ChatOutcome) Refund() bool {
	if len(o.line) > 0 {
		o.frame()
	}
	return o.failed && !o.reply
}
