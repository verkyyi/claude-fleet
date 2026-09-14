package store

import "github.com/verkyyi/ccquota/internal/i18n"

// providerNote is ProviderNote in every language this build ships. The English
// entry is the constant itself, so the two cannot drift.
var providerNote = i18n.Text{
	i18n.EN: ProviderNote,
	i18n.ZhCN: "上游为空，意思是上报的那一侧没有声明上游：" +
		"Claude 的 transcript 本来就不带上游信息；而在本 hub 有「上游」这个维度之前就已经聚合好的小时行，" +
		"也没有回头重新归属 —— 它们宁可留空，也不会被安到一个未必属于它们的厂商头上。" +
		"vendor_bill 的行原则上总有厂商，因为它就是从那家厂商的发票上读来的；" +
		"那里出现空值，说明采集器没有把它填上。",
}

// ProviderNoteIn is ProviderNote in a viewer's language.
func ProviderNoteIn(locale string) string { return providerNote.In(locale) }

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
	UnpricedNoGatewayRate         = "no_gateway_rate"
	UnpricedGatewayCacheToken     = "gateway_cache_token"
	UnpricedGatewayFX             = "gateway_fx"
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
	UnpricedNoGatewayRate:         {i18n.EN: "No gateway rate configured for this model", i18n.ZhCN: "这个模型没有配置网关费率"},
	UnpricedGatewayCacheToken:     {i18n.EN: "Gateway cache-token price unavailable", i18n.ZhCN: "网关费率不含缓存 token 的价格"},
	UnpricedGatewayFX:             {i18n.EN: "Gateway currency conversion unavailable", i18n.ZhCN: "没有可用的人民币 / 美元汇率"},
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
