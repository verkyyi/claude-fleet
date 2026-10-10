package rolemerge

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"
)

// OMap is a JSON object that keeps its keys' order — python's dict, which the
// merge leans on (mcpServers comes out in the order its servers went in).
type OMap struct {
	Keys []string
	Vals map[string]any
}

// NewOMap is an empty object.
func NewOMap() *OMap { return &OMap{Vals: map[string]any{}} }

// Get is the value under k and whether it is there.
func (m *OMap) Get(k string) (any, bool) {
	if m == nil {
		return nil, false
	}
	v, ok := m.Vals[k]
	return v, ok
}

// Set puts v under k, keeping k's place when it is already there.
func (m *OMap) Set(k string, v any) {
	if _, ok := m.Vals[k]; !ok {
		m.Keys = append(m.Keys, k)
	}
	m.Vals[k] = v
}

// Del removes k.
func (m *OMap) Del(k string) {
	if _, ok := m.Vals[k]; !ok {
		return
	}
	delete(m.Vals, k)
	for i, x := range m.Keys {
		if x == k {
			m.Keys = append(m.Keys[:i:i], m.Keys[i+1:]...)
			break
		}
	}
}

// Len is how many keys it holds.
func (m *OMap) Len() int {
	if m == nil {
		return 0
	}
	return len(m.Keys)
}

// Copy is a shallow copy.
func (m *OMap) Copy() *OMap {
	out := NewOMap()
	if m != nil {
		for _, k := range m.Keys {
			out.Set(k, m.Vals[k])
		}
	}
	return out
}

// MarshalJSON writes the keys in their order.
func (m *OMap) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, k := range m.Keys {
		if i > 0 {
			b.WriteByte(',')
		}
		kb, _ := marshal(k)
		b.Write(kb)
		b.WriteByte(':')
		vb, err := marshal(m.Vals[k])
		if err != nil {
			return nil, err
		}
		b.Write(vb)
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}

// UnmarshalJSON reads an object keeping its order (nested objects too).
func (m *OMap) UnmarshalJSON(data []byte) error {
	v, err := Decode(data)
	if err != nil {
		return err
	}
	o, ok := v.(*OMap)
	if !ok {
		return fmt.Errorf("not a JSON object")
	}
	*m = *o
	return nil
}

func marshal(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}

// Decode reads JSON with every object an *OMap, every number a json.Number.
func Decode(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	v, err := decodeValue(dec)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("trailing data after JSON value")
	}
	return v, nil
}

func decodeValue(dec *json.Decoder) (any, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			m := NewOMap()
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				k, _ := kt.(string)
				v, err := decodeValue(dec)
				if err != nil {
					return nil, err
				}
				m.Set(k, v)
			}
			_, err := dec.Token()
			return m, err
		case '[':
			out := []any{}
			for dec.More() {
				v, err := decodeValue(dec)
				if err != nil {
					return nil, err
				}
				out = append(out, v)
			}
			_, err := dec.Token()
			return out, err
		}
		return nil, fmt.Errorf("unexpected %v", t)
	default:
		return tok, nil
	}
}

// Canonical is v as JSON with every object's keys sorted and nothing escaped
// that need not be — python's json.dumps(v, sort_keys=True, ensure_ascii=False,
// separators=(',', ':')), what two copies of the merge are compared by.
func Canonical(v any) string {
	var b strings.Builder
	canon(&b, v)
	return b.String()
}

func canon(b *strings.Builder, v any) {
	switch t := v.(type) {
	case *OMap:
		keys := append([]string(nil), t.Keys...)
		sort.Strings(keys)
		b.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			kb, _ := marshal(k)
			b.Write(kb)
			b.WriteByte(':')
			canon(b, t.Vals[k])
		}
		b.WriteByte('}')
	case map[string]any:
		m := NewOMap()
		for k, x := range t {
			m.Set(k, x)
		}
		canon(b, m)
	case []any:
		b.WriteByte('[')
		for i, x := range t {
			if i > 0 {
				b.WriteByte(',')
			}
			canon(b, x)
		}
		b.WriteByte(']')
	case []string:
		l := make([]any, len(t))
		for i, x := range t {
			l[i] = x
		}
		canon(b, l)
	default:
		vb, _ := marshal(t)
		b.Write(vb)
	}
}
