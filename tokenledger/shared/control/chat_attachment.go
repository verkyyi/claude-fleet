package control

import "regexp"

const CapChatAttachment = "chat-attachment-v1"
const ChatAttachmentDataPath = "/v1/node/chat-attachment"
const ChatBodyMax = 1 << 20

var chatRequestID = regexp.MustCompile(`^[0-9a-f]{32}$`)

// One independently authorized HTTP request per attachment. No caller-supplied
// method, headers, URL or socket crosses this boundary. Client is hub metadata.
type ChatAttachmentRequest struct {
	ID     string `json:"id,omitempty"`
	Bytes  int    `json:"bytes,omitempty"`
	Rate   int64  `json:"rate,omitempty"`
	Client string `json:"client,omitempty"`
}

func (r ChatAttachmentRequest) Valid(target string) bool {
	return chatRequestID.MatchString(r.ID) && r.Bytes >= 0 && r.Bytes <= ChatBodyMax &&
		len(r.Client) <= 4096 && (target != "conversation" || r.Bytes == 0)
}

// Binary frames are body chunks. Text frames mark request end, response
// headers/end, cancellation and ready; HTTP headers are an explicit allowlist.
type ChatAttachmentFrame struct {
	T           string `json:"t"`
	Status      int    `json:"status,omitempty"`
	ContentType string `json:"content_type,omitempty"`
	Error       string `json:"error,omitempty"`
}
