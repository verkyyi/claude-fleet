// Package schedule defines the self-service contract. The node supervisor alone
// evaluates due slots; this package only validates policy and wire data.
package schedule

import (
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	_ "time/tzdata"
)

const MaxTasks = 10
const MaxDailySlots = 24
const MaxDailyStarts = 30
const Capability = "schedule_v1"
const AgentCapability = "schedule_agent_v1"
const JobCapability = "schedule_jobs_v1"

type Delivery struct {
	WeChat   bool `json:"wechat"`
	LivePage bool `json:"livepage"`
}

// Execution is opt-in. Nil preserves the recurring contract; one-shot jobs
// never retry unless explicitly requested. All attempts share result/delivery.
type Execution struct {
	TimeoutSeconds    int  `json:"timeout_seconds,omitempty"`
	Retries           *int `json:"retries,omitempty"`
	RetryDelaySeconds int  `json:"retry_delay_seconds,omitempty"`
}

func (s Spec) Policy() (timeout, retries, delay int) {
	timeout, retries, delay = 3600, 2, 300
	if s.OnceAt != 0 {
		retries = 0
	}
	if p := s.Execution; p != nil {
		if p.TimeoutSeconds != 0 {
			timeout = p.TimeoutSeconds
		}
		if p.Retries != nil {
			retries = *p.Retries
		}
		if p.RetryDelaySeconds != 0 {
			delay = p.RetryDelaySeconds
		}
	}
	return
}

type Spec struct {
	OnceAt    int64      `json:"once_at,omitempty"`
	Execution *Execution `json:"execution,omitempty"`
	ID        string     `json:"id"`
	Revision  int64      `json:"revision"`
	Name      string     `json:"name"`
	Prompt    string     `json:"prompt"`
	Agent     string     `json:"agent,omitempty"`
	At        string     `json:"at,omitempty"`
	Cron      string     `json:"cron,omitempty"`
	Timezone  string     `json:"timezone"`
	Enabled   bool       `json:"enabled"`
	Deleted   bool       `json:"deleted"`
	Delivery  Delivery   `json:"delivery"`
	Repo      string     `json:"repo,omitempty"`
	Entry     string     `json:"entry,omitempty"`
}

var ID = regexp.MustCompile(`^schedule-[a-z0-9-]{1,38}$`)
var Entry = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,47}$`)
var Repo = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)

func field(s string, lo, hi int) ([]int, error) {
	values := map[int]bool{}
	for _, part := range strings.Split(s, ",") {
		step := 1
		base, raw, has := strings.Cut(part, "/")
		if has {
			n, e := strconv.Atoi(raw)
			if e != nil || n < 1 || n > hi-lo+1 {
				return nil, errors.New("invalid cron step")
			}
			step = n
		}
		a, b := lo, hi
		if base != "*" {
			first, last, ranged := strings.Cut(base, "-")
			n, e := strconv.Atoi(first)
			if e != nil {
				return nil, e
			}
			a = n
			b = n
			if has && step > 1 {
				b = hi
			}
			if ranged {
				n, e = strconv.Atoi(last)
				if e != nil {
					return nil, e
				}
				b = n
			}
		}
		if a < lo || b > hi || a > b {
			return nil, errors.New("cron field outside range")
		}
		for n := a; n <= b; n += step {
			values[n] = true
		}
	}
	out := make([]int, 0, len(values))
	for n := range values {
		out = append(out, n)
	}
	sort.Ints(out)
	return out, nil
}

// Validate returns a conservative per-day slot reservation. Calendar restrictions
// do not buy extra burst capacity; all tasks together reserve at most 24/day.
func Validate(s Spec) (int, error) {
	timeout, retries, delay := s.Policy()
	if timeout < 60 || timeout > 3600 || retries < 0 || retries > 2 || delay < 300 || delay > 86400 {
		return 0, errors.New("execution requires timeout_seconds 60..3600, retries 0..2, retry_delay_seconds 300..86400")
	}
	if s.Agent != "" && s.Agent != "claude" && s.Agent != "codex" {
		return 0, errors.New("agent must be claude or codex (empty uses fleet default)")
	}
	if !ID.MatchString(s.ID) || s.Revision < 1 {
		return 0, errors.New("invalid id or revision")
	}
	if strings.TrimSpace(s.Name) == "" || len([]rune(s.Name)) > 120 || strings.ContainsAny(s.Name, "\x00\r\n") {
		return 0, errors.New("name must be 1–120 characters")
	}
	if strings.TrimSpace(s.Prompt) == "" || len([]rune(s.Prompt)) > 16000 || strings.ContainsRune(s.Prompt, 0) {
		return 0, errors.New("prompt must be 1–16000 characters")
	}
	if len(s.Cron) > 256 || len(s.Timezone) > 100 || len(s.Repo) > 256 {
		return 0, errors.New("schedule field too long")
	}
	if s.Entry != "" && !Entry.MatchString(s.Entry) {
		return 0, errors.New("invalid existing task name")
	}
	if s.Repo != "" && !Repo.MatchString(s.Repo) {
		return 0, errors.New("invalid repository")
	}
	if s.Timezone == "" {
		return 0, errors.New("timezone is required")
	}
	if _, e := time.LoadLocation(s.Timezone); e != nil {
		return 0, errors.New("unknown timezone")
	}
	if s.OnceAt != 0 {
		if s.OnceAt < 1 || s.OnceAt > 253402300799 || s.At != "" || s.Cron != "" || s.Entry != "" {
			return 0, errors.New("once_at must be a positive epoch; cannot combine with at, cron or adopt")
		}
		return 0, nil // one shot reserves a start, never a recurring daily slot
	}
	if (s.At == "") == (s.Cron == "") {
		return 0, errors.New("provide at or cron, not both")
	}
	expr := s.Cron
	if s.At != "" {
		t, e := time.Parse("15:04", s.At)
		if e != nil {
			return 0, errors.New("at must be HH:MM")
		}
		expr = fmt.Sprintf("%d %d * * *", t.Minute(), t.Hour())
	}
	fields := strings.Fields(expr)
	if len(fields) != 5 {
		return 0, errors.New("cron must have five fields")
	}
	limits := [][2]int{{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 7}}
	sets := make([][]int, 5)
	for i, f := range fields {
		v, e := field(f, limits[i][0], limits[i][1])
		if e != nil {
			return 0, e
		}
		sets[i] = v
	}
	times := []int{}
	for _, h := range sets[1] {
		for _, m := range sets[0] {
			times = append(times, h*60+m)
		}
	}
	sort.Ints(times)
	if len(times) == 0 {
		return 0, errors.New("no matching time")
	}
	for i, a := range times {
		b := times[(i+1)%len(times)]
		if i == len(times)-1 {
			b += 1440
		}
		if b-a < 60 {
			return 0, errors.New("minimum interval is one hour")
		}
	}
	return len(times), nil
}

// DueSlot validates a daemon's claimed occurrence for admission. It never
// selects or triggers a future run; only the node's task_slot owns that clock.
func DueSlot(s Spec, slot string, now time.Time) bool {
	epoch, err := strconv.ParseInt(slot, 10, 64)
	if s.OnceAt != 0 {
		return err == nil && epoch == s.OnceAt && epoch <= now.Unix()
	}
	if err != nil || epoch > now.Unix() || now.Unix()-epoch > 6*3600 {
		return false
	}
	loc, err := time.LoadLocation(s.Timezone)
	if err != nil {
		return false
	}
	t := time.Unix(epoch, 0).In(loc)
	if t.Second() != 0 {
		return false
	}
	if s.At != "" {
		return t.Format("15:04") == s.At
	}
	f := strings.Fields(s.Cron)
	if len(f) != 5 {
		return false
	}
	limits := [][2]int{{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 7}}
	values := []int{t.Minute(), t.Hour(), t.Day(), int(t.Month()), int(t.Weekday())}
	matched := make([]bool, 5)
	for i, expr := range f {
		set, e := field(expr, limits[i][0], limits[i][1])
		if e != nil {
			return false
		}
		for _, v := range set {
			if i == 4 {
				v %= 7
			}
			if v == values[i] {
				matched[i] = true
			}
		}
	}
	day := matched[2] && matched[4]
	if f[2] != "*" && f[4] != "*" {
		day = matched[2] || matched[4]
	}
	return matched[0] && matched[1] && matched[3] && day
}

// Preview is a read-only calendar projection for the edit form. It does not
// persist a due time or participate in dispatch; the node daemon remains the
// only clock. Keep the calendar/DST cases pinned against task_slot fixtures.
func Preview(s Spec, after time.Time) (time.Time, error) {
	if _, e := Validate(s); e != nil {
		return time.Time{}, e
	}
	if s.OnceAt != 0 {
		if s.OnceAt <= after.Unix() {
			return time.Time{}, errors.New("one-shot time has passed")
		}
		return time.Unix(s.OnceAt, 0), nil
	}
	loc, _ := time.LoadLocation(s.Timezone)
	expr := s.Cron
	if s.At != "" {
		t, _ := time.Parse("15:04", s.At)
		expr = fmt.Sprintf("%d %d * * *", t.Minute(), t.Hour())
	}
	f := strings.Fields(expr)
	limits := [][2]int{{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 7}}
	sets := make([][]int, 5)
	for i := range f {
		sets[i], _ = field(f[i], limits[i][0], limits[i][1])
	}
	contains := func(set []int, n int, dow bool) bool {
		for _, v := range set {
			if dow {
				v %= 7
			}
			if v == n {
				return true
			}
		}
		return false
	}
	local := after.In(loc)
	// Noon avoids midnight transitions while enumerating calendar dates.
	start := time.Date(local.Year(), local.Month(), local.Day(), 12, 0, 0, 0, loc)
	for day := 0; day < 400; day++ {
		d := start.AddDate(0, 0, day)
		if !contains(sets[3], int(d.Month()), false) {
			continue
		}
		dm, dw := contains(sets[2], d.Day(), false), contains(sets[4], int(d.Weekday()), true)
		match := dm && dw
		if f[2] != "*" && f[4] != "*" {
			match = dm || dw
		}
		if !match {
			continue
		}
		for _, h := range sets[1] {
			for _, m := range sets[0] {
				t := time.Date(d.Year(), d.Month(), d.Day(), h, m, 0, 0, loc)
				same := func(v time.Time) bool {
					return v.Year() == d.Year() && v.Month() == d.Month() && v.Day() == d.Day() && v.Hour() == h && v.Minute() == m
				}
				if !same(t) {
					continue
				}
				_, oldOffset := t.Add(-24 * time.Hour).Zone()
				_, offset := t.Zone()
				if oldOffset > offset {
					early := t.Add(time.Duration(offset-oldOffset) * time.Second)
					if same(early) {
						t = early
					}
				}
				if t.After(after) {
					return t, nil
				}
			}
		}
	}
	return time.Time{}, errors.New("no occurrence within 400 days")
}
