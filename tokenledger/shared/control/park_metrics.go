package control

// ParkMetrics is one login's complete census, summed once per heard login at
// the hub. A nil census is an older/unreadable node, never zero savings.
type ParkMetrics struct {
	SessionsWorking int            `json:"sessions_working"`
	SessionsIdle    int            `json:"sessions_idle"`
	SessionsParked  int            `json:"sessions_parked"`
	IdleRSSMB       *float64       `json:"idle_rss_mb"`
	ParkedSavedMB   float64        `json:"parked_saved_mb"`
	IdleReasons     map[string]int `json:"idle_reasons"`
	// IdleEligible uses the batch definition: turn over, <0.5 CPU seconds
	// over 60 seconds, no human watching and no background job. nil until sampled.
	IdleEligible      *int     `json:"idle_eligible"`
	IdleEligibleRSSMB *float64 `json:"idle_eligible_rss_mb"`
}

func (p *ParkMetrics) Add(other *ParkMetrics) {
	p.SessionsWorking += other.SessionsWorking
	p.SessionsIdle += other.SessionsIdle
	p.SessionsParked += other.SessionsParked
	p.ParkedSavedMB += other.ParkedSavedMB
	if p.IdleRSSMB != nil && other.IdleRSSMB != nil {
		*p.IdleRSSMB += *other.IdleRSSMB
	} else {
		p.IdleRSSMB = nil
	}
	if p.IdleEligibleRSSMB != nil && other.IdleEligibleRSSMB != nil {
		*p.IdleEligibleRSSMB += *other.IdleEligibleRSSMB
	} else {
		p.IdleEligibleRSSMB = nil
	}
	if p.IdleEligible != nil && other.IdleEligible != nil {
		*p.IdleEligible += *other.IdleEligible
	} else {
		p.IdleEligible = nil
	}
	if p.IdleReasons == nil {
		p.IdleReasons = map[string]int{}
	}
	for why, count := range other.IdleReasons {
		p.IdleReasons[why] += count
	}
}

func EmptyParkMetrics() *ParkMetrics {
	rss, eligibleRSS, eligible := 0.0, 0.0, 0
	return &ParkMetrics{IdleRSSMB: &rss, IdleEligible: &eligible, IdleEligibleRSSMB: &eligibleRSS, IdleReasons: map[string]int{}}
}
