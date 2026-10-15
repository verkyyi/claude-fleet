package agent

import (
	"encoding/json"
	"errors"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"io"
)

// This pipe is inherited only by the fixed lifecycle helper. Terminal output
// cannot impersonate admission. Paths never come from a browser or a grant.
type termController struct {
	TTL   int    `json:"ttl"`
	State string `json:"state"`
	Term  string `json:"term"`
	Gen   string `json:"gen"`
	Conn  string `json:"conn"`
	Epoch uint64 `json:"epoch"`
	Lock  string `json:"lock"`
	Lease string `json:"lease"`
}

var readTermAdmission = func(r io.Reader) (termController, error) {
	var c termController
	err := json.NewDecoder(io.LimitReader(r, 4096)).Decode(&c)
	if err != nil {
		return c, err
	}
	if c.State != "controller" {
		return c, errors.New(c.State)
	}
	if c.Term == "" || c.Gen == "" || c.Conn == "" || c.Epoch == 0 || c.Lock == "" || c.Lease == "" {
		return c, errors.New("invalid controller admission")
	}
	return c, nil
}

func (c termController) ready() control.TermControl {
	return control.TermControl{T: "ready", Term: c.Term, Gen: c.Gen, Epoch: c.Epoch}
}
