package control

// ParkMetrics is one login's complete census, summed once per heard login at
// the hub. A nil census is an older/unreadable node, never zero savings.
type ParkMetrics struct {
	SessionsWorking *int           `json:"sessions_working"`
	SessionsIdle    *int           `json:"sessions_idle"`
	SessionsParked  int            `json:"sessions_parked"`
	IdleRSSMB       *float64       `json:"idle_rss_mb"`
	ParkedSavedMB   *float64       `json:"parked_saved_mb"`
	IdleReasons     map[string]int `json:"idle_reasons"`
	// Resident idle includes viewers and background jobs. This strict subset is
	// the batch acceptance metric: turn over, low CPU, no viewer or background job.
	IdleEligible      *int     `json:"idle_eligible"`
	IdleEligibleRSSMB *float64 `json:"idle_eligible_rss_mb"`
}

func (p *ParkMetrics) Add(other *ParkMetrics) {
	if p.SessionsWorking != nil && other.SessionsWorking != nil {
		*p.SessionsWorking += *other.SessionsWorking
	} else {
		p.SessionsWorking = nil
	}
	if p.SessionsIdle != nil && other.SessionsIdle != nil {
		*p.SessionsIdle += *other.SessionsIdle
	} else {
		p.SessionsIdle = nil
	}
	p.SessionsParked += other.SessionsParked
	if p.ParkedSavedMB != nil && other.ParkedSavedMB != nil {
		*p.ParkedSavedMB += *other.ParkedSavedMB
	} else {
		p.ParkedSavedMB = nil
	}
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
	rss, saved, eligibleRSS, eligible, idle, working := 0.0, 0.0, 0.0, 0, 0, 0
	return &ParkMetrics{SessionsWorking: &working, SessionsIdle: &idle, IdleRSSMB: &rss, ParkedSavedMB: &saved, IdleEligible: &eligible, IdleEligibleRSSMB: &eligibleRSS, IdleReasons: map[string]int{}}
}
