package store

import "github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"

// The reasons a request has no price, as codes rather than sentences.
//
// A surface that wants to restate one in another language matches on these, not
// on the English text — matching prose is how a wording fix silently turns into
// a missing translation.
const (
	UnpricedCacheWriteUnavailable = "cache_write_unavailable"
	UnpricedCacheWriteUnsupported = "cache_write_unsupported"
	UnpricedUnknownModel          = "unknown_model"
	UnpricedLegacyFast            = "legacy_fast"
	UnpricedServiceTier           = "service_tier"
	UnpricedImplausibleTokens     = "implausible_tokens"
	UnpricedNoPriceData           = "no_price_data"
	UnpricedPruned                = "pruned"
)

var unpricedReasons = map[string]i18n.Text{
	UnpricedCacheWriteUnavailable: {i18n.EN: "Cache-write token breakdown unavailable", i18n.ZhCN: "拿不到缓存写入的 token 拆分"},
	UnpricedCacheWriteUnsupported: {i18n.EN: "Cache-write token breakdown unsupported", i18n.ZhCN: "不支持缓存写入的 token 拆分"},
	UnpricedUnknownModel:          {i18n.EN: "Verified provider/model price unavailable", i18n.ZhCN: "没有已核实的厂商 / 模型价格"},
	UnpricedLegacyFast:            {i18n.EN: "Legacy Fast price not verified", i18n.ZhCN: "旧版 Fast 档价格未核实"},
	UnpricedServiceTier:           {i18n.EN: "Service-tier price unavailable", i18n.ZhCN: "拿不到服务档位的价格"},
	UnpricedImplausibleTokens:     {i18n.EN: "Implausible token counts", i18n.ZhCN: "token 数不可信"},
	UnpricedNoPriceData:           {i18n.EN: "Price data unavailable", i18n.ZhCN: "拿不到价格数据"},
	UnpricedPruned:                {i18n.EN: "Historical request details no longer retained", i18n.ZhCN: "历史请求明细已经不再保留"},
}

// UnpricedReasonIn names one unpriced-reason code in a viewer's language. An
// unknown code falls back to the generic "no price data" rather than to a blank
// cell in a table whose whole job is explaining an absence.
func UnpricedReasonIn(code, locale string) string {
	if txt, ok := unpricedReasons[code]; ok {
		return txt.In(locale)
	}
	return unpricedReasons[UnpricedNoPriceData].In(locale)
}
