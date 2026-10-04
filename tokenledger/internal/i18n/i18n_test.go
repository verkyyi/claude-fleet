package i18n

import (
	"net/http/httptest"
	"testing"
)

func TestNormalize(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"", EN},
		{"en", EN},
		{"EN", EN},
		{"en-US", EN},
		{"zh-CN", ZhCN},
		{"zh-cn", ZhCN},
		{"zh", ZhCN},
		// This build ships no Traditional dictionary. Simplified is much closer
		// to what a zh-TW reader wants than English is, so it resolves there
		// rather than falling all the way back.
		{"zh-TW", ZhCN},
		{"zh-Hant-HK", ZhCN},
		{"fr-FR", EN},
		{"  zh-CN  ", ZhCN},
	} {
		if got := Normalize(tc.in); got != tc.want {
			t.Errorf("Normalize(%q) = %q; want %q", tc.in, got, tc.want)
		}
	}
}

func TestFromRequest_QueryBeatsHeader(t *testing.T) {
	// The dashboard sends the language the viewer CHOSE, which is routinely not
	// what their browser advertises. The explicit parameter has to win, or the
	// switcher silently does nothing for anyone whose browser disagrees with it.
	r := httptest.NewRequest("GET", "/v1/summary?locale=zh-CN", nil)
	r.Header.Set("Accept-Language", "en-US,en;q=0.9")
	if got := FromRequest(r); got != ZhCN {
		t.Errorf("locale = %q; want the query parameter to win", got)
	}
}

func TestFromRequest_FallsBackToHeader(t *testing.T) {
	// A bare curl, or a dashboard build older than this change, still gets
	// something sensible instead of always English.
	r := httptest.NewRequest("GET", "/v1/summary", nil)
	r.Header.Set("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
	if got := FromRequest(r); got != ZhCN {
		t.Errorf("locale = %q; want %q from Accept-Language", got, ZhCN)
	}
	if got := FromRequest(httptest.NewRequest("GET", "/v1/summary", nil)); got != EN {
		t.Errorf("no header: locale = %q; want %q", got, EN)
	}
	if got := FromRequest(nil); got != EN {
		t.Errorf("nil request: locale = %q; want %q", got, EN)
	}
}

func TestFromAcceptLanguage(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"", EN},
		{"*", EN},
		{"en-GB,en;q=0.9", EN},
		{"zh-CN,en;q=0.9", ZhCN},
		// The first tag this build HAS wins; an unknown one is skipped rather
		// than ending the search at English.
		{"fr-FR,zh-CN;q=0.8", ZhCN},
		{"fr,de", EN},
	} {
		if got := FromAcceptLanguage(tc.in); got != tc.want {
			t.Errorf("FromAcceptLanguage(%q) = %q; want %q", tc.in, got, tc.want)
		}
	}
}

func TestTextIn_FallsBackToEnglish(t *testing.T) {
	txt := Text{EN: "english", ZhCN: "中文"}
	if got := txt.In(ZhCN); got != "中文" {
		t.Errorf("In(zh-CN) = %q", got)
	}
	if got := txt.In("fr"); got != "english" {
		t.Errorf("In(fr) = %q; want the English fallback", got)
	}
	// A half-filled dictionary must show the English sentence. A blank where a
	// caveat about money belongs is the one outcome worse than the wrong
	// language.
	half := Text{EN: "english", ZhCN: ""}
	if got := half.In(ZhCN); got != "english" {
		t.Errorf("empty translation: In(zh-CN) = %q; want the English text", got)
	}
}
