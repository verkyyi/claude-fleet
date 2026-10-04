package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/badge"
	"github.com/verkyyi/ccquota/internal/store"
)

// dayPeriod matches the only relative window a badge may carry.
//
// Go's time.ParseDuration has no day unit and would accept "24h" while
// rejecting "30d", which is backwards for a badge: the label a reader
// understands is days. Anything else is refused rather than quietly falling
// back to all-time, because a lifetime figure under a "7d" label is a lie.
var dayPeriod = regexp.MustCompile(`^([1-9][0-9]*)d$`)

func periodRange(period string, now time.Time) (start time.Time, all bool, err error) {
	if period == "" || period == "all" {
		return time.Time{}, true, nil
	}
	m := dayPeriod.FindStringSubmatch(period)
	if m == nil {
		return time.Time{}, false, fmt.Errorf(
			"unknown period %q: use \"all\" or a number of days like \"30d\"", period)
	}
	n, err := strconv.Atoi(m[1])
	if err != nil {
		return time.Time{}, false, fmt.Errorf("unknown period %q", period)
	}
	return now.AddDate(0, 0, -n), false, nil
}

func runBadge(args []string) error {
	fs := flag.NewFlagSet("badge", flag.ExitOnError)
	dbPath := fs.String("db", "", "the hub's database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	// ★ 远端模式：hub 搬进集群之后，**发布这张图的机器上已经没有那个库了**。
	//   给它一条只读的取数路：问 hub 要同一个 LifetimeTotals，渲染不变。
	//   不给 --hub 就还是本地库，行为逐字节不变。
	// ★ **不从环境变量取默认值**（token 可以，hub 不行）。本命令的契约是「完全本地、
	//   不碰网络」——`TestRunBadge_WritesSVGWithoutNetwork` 就是钉这条的。让 --hub 默认
	//   读 CCQUOTA_HUB_URL 会**静默**把一条离线命令变成联网命令：环境里恰好有那个变量的
	//   机器上，`ccquota badge` 会突然开始打网络，而调用方什么都没改。要远端就显式写出来。
	hub := fs.String("hub", "", "read totals from a hub over HTTP instead of a local database (explicit only)")
	hubToken := fs.String("token", os.Getenv("CCQUOTA_VIEWER_TOKEN"), "viewer token, with --hub")
	out := fs.String("out", "", "write to this file (default: stdout)")
	theme := fs.String("theme", "dark", "\"dark\", \"light\", or \"auto\" (follows the reader's\n"+
		"OS colour scheme; on GitHub use two files and <picture>, since its\n"+
		"own theme toggle can disagree with the OS)")
	from := fs.Int64("from", 0, "roll the odometer from this previous count rather than from zero")
	transparent := fs.Bool("transparent", false, "no ground; the host's own background shows through")
	pac := fs.String("pac", "", "hex colour override for the character, e.g. ff0000")
	dot := fs.String("dot", "", "hex colour override for the dots")
	fg := fs.String("fg", "", "hex colour override for digits and label")
	bg := fs.String("bg", "", "hex colour override for the ground")
	period := fs.String("period", "all", "\"all\", or a window like \"30d\"")
	style := fs.String("style", badge.StyleTokenman,
		"\"tokenman\" (animated odometer, the exact count) or \"flat\" (static, shields-shaped)")
	size := fs.String("size", "full", "\"full\" (48px) or \"compact\" (20px, sits in a row of shields badges)")
	asJSON := fs.Bool("json", false, "emit shields.io endpoint JSON instead of an SVG")
	fs.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage:
  ccquota badge --out ccquota.svg --theme dark --period all
  ccquota badge --size compact --out ccquota-sm.svg   # 20px, beside shields badges
  ccquota badge --style flat --out ccquota-flat.svg   # static, shields-shaped
  ccquota badge --json --out ccquota.json             # shields.io endpoint schema

Renders this hub's totals as a badge. Entirely local: no server, no account,
no submission, and the rendered SVG contains no external reference of any kind
(an <img>-loaded SVG cannot fetch scripts, fonts, CSS or images).

Publish the result however you like -- commit the SVG to a profile repo and
reference it by raw.githubusercontent.com, or write the JSON to a gist and
point img.shields.io at it.

Flags:
`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *theme != "dark" && *theme != "light" && *theme != "auto" {
		return fmt.Errorf("unknown theme %q: use \"dark\", \"light\" or \"auto\"", *theme)
	}
	if *style != badge.StyleTokenman && *style != badge.StyleFlat {
		return fmt.Errorf("unknown style %q: use \"tokenman\" or \"flat\"", *style)
	}
	if *size != "full" && *size != "compact" {
		return fmt.Errorf("unknown size %q: use \"full\" or \"compact\"", *size)
	}

	var (
		d   badge.Data
		err error
	)
	if *hub != "" {
		// 远端只认 all-time：hub 的 /v1/live 给的就是 LifetimeTotals 那一个数。
		// 窗口口径要另一个端点，而这条路的唯一用途是发那张全时长的图 —— 与其
		// 悄悄换个口径渲染出一张“看起来对”的图，不如当场说不支持。
		if *period != "" && *period != "all" {
			return fmt.Errorf("--period %s needs a local database; --hub only serves all-time totals", *period)
		}
		d, err = hubBadgeData(*hub, *hubToken, *theme)
	} else {
		var dbFile string
		dbFile, err = resolveExistingDB(*dbPath)
		if err != nil {
			return err
		}
		var st *store.Store
		st, err = store.Open(dbFile)
		if err != nil {
			return err
		}
		defer st.Close()
		d, err = badgeData(st, *period, *theme)
	}
	if err != nil {
		return err
	}
	d.Style, d.Size = *style, *size
	d.From, d.Transparent = *from, *transparent
	d.Colors = badge.Colors{Pac: *pac, Dot: *dot, FG: *fg, BG: *bg}

	var payload []byte
	if *asJSON {
		payload, err = json.MarshalIndent(badge.ToShields(d), "", "  ")
		if err != nil {
			return fmt.Errorf("encode shields JSON: %w", err)
		}
		payload = append(payload, '\n')
	} else {
		payload = badge.Render(d)
	}

	if *out == "" {
		_, err = os.Stdout.Write(payload)
		return err
	}
	if err := os.WriteFile(*out, payload, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", *out, err)
	}
	fmt.Fprintf(os.Stderr, "wrote %s (%s, %s)\n", *out, d.LabelText(), d.MessageText())
	return nil
}

// badgeData reads the figure the badge shows.
//
// All-time uses LifetimeTotals, which is the same expression every other total
// on this hub uses. A windowed period sums the per-account buckets and discards
// their keys -- the badge must never carry an account identifier.
func badgeData(st *store.Store, period, theme string) (badge.Data, error) {
	d := badge.Data{Period: period, Theme: theme}
	if d.Period == "" {
		d.Period = "all"
	}

	start, all, err := periodRange(period, time.Now().UTC())
	if err != nil {
		return d, err
	}
	if all {
		turns, tokens, err := st.LifetimeTotals()
		if err != nil {
			return d, err
		}
		d.Turns, d.Tokens = turns, tokens
		return d, nil
	}

	buckets, err := st.UsageBy(store.AllAccounts, store.ByAccount, start, time.Now().UTC(), 1000)
	if err != nil {
		return d, err
	}
	for _, b := range buckets {
		d.Turns += b.Events
		d.Tokens += b.Tokens
	}
	return d, nil
}

// hubBadgeData asks a hub for the same all-time figure `badgeData` computes
// locally.
//
// Why this exists: the hub moved into the cluster, and the machine that
// publishes this SVG no longer has the database. Reading it over HTTP keeps one
// number behind both artefacts — the alternative (publish a frozen SVG next to
// a live JSON) is exactly the drift that made the website and the dashboard
// disagree by 1.5B tokens once already.
func hubBadgeData(hubURL, token, theme string) (badge.Data, error) {
	d := badge.Data{Period: "all", Theme: theme}
	req, err := http.NewRequest(http.MethodGet, strings.TrimRight(hubURL, "/")+"/v1/live", nil)
	if err != nil {
		return d, err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return d, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return d, fmt.Errorf("hub returned HTTP %d", resp.StatusCode)
	}
	var body struct {
		Counter *struct {
			Turns  int64 `json:"turns"`
			Tokens int64 `json:"tokens"`
		} `json:"counter"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&body); err != nil {
		return d, err
	}
	// ★ 拿不到计数器就报错，不要渲染一张 0 的图 —— 一张写着 0 的里程表比没有图更糟：
	//   它看起来是个事实。
	if body.Counter == nil || body.Counter.Tokens <= 0 {
		return d, fmt.Errorf("hub returned no counter")
	}
	d.Turns, d.Tokens = body.Counter.Turns, body.Counter.Tokens
	return d, nil
}
