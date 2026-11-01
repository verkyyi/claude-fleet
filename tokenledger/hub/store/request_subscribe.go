package store

import "database/sql"

// A browser's acceptance is only a hint: WeChat enforces the actual grant at
// send time. Bind that hint to one pending request, its openid and template.
// Never rearm a consumed hint, even if a browser repeats its success event.
func (s *Store) GrantRequestSubscribe(id, kind, subject, openid, tpl string) (bool, error) {
	res, err := s.write.Exec(`INSERT INTO hub_request_subscribe(request_id, openid, template_id, consumed)
		SELECT id, ?, ?, 0 FROM hub_access_requests WHERE id = ? AND kind = ? AND subject = ? AND state = 'pending' AND notify_channel = 'wechat'
		ON CONFLICT(request_id) DO UPDATE SET openid = excluded.openid, template_id = excluded.template_id
		WHERE hub_request_subscribe.consumed = 0`, openid, tpl, id, kind, subject)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// Claim before calling WeChat. An ambiguous network failure must not spend a
// second grant on a retry; the ordinary template/email roads remain available.
func (s *Store) ClaimRequestSubscribe(id, tpl string) (string, error) {
	var openid string
	err := s.write.QueryRow(`UPDATE hub_request_subscribe SET consumed = 1
		WHERE request_id = ? AND template_id = ? AND consumed = 0 RETURNING openid`, id, tpl).Scan(&openid)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return openid, err
}
