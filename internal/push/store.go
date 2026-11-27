package push

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// PgStore — Store'ning Neon (Postgres) dagi amalga oshirilishi.
// Jadvallar: notification_outbox (push_sent_at, link), push_tokens (sql/app.sql).
type PgStore struct {
	DB *pgxpool.Pool
}

// multiRoleSQL — foydalanuvchi bir nechta rolda: admin, usta profili, e'lon bergan mijoz, do'kon (2 va ko'p).
// usr — users jadvali, u.user_id — xabar egasi.
const multiRoleSQL = `(coalesce((to_jsonb(usr)->>'is_admin')::boolean, false)::int
		       + exists (select 1 from provider_profiles pp where pp.user_id = u.user_id)::int
		       + exists (select 1 from jobs j where j.client_id = u.user_id)::int
		       + exists (select 1 from shop_profiles sp where sp.user_id = u.user_id)::int) > 1`

func (s *PgStore) Claim(ctx context.Context, limit int) (int, []Message, error) {
	// Tokeni yo'q foydalanuvchining xabari ham belgilanadi va "claimed" ga kiradi (select count(*) from u);
	// left join'da token null bo'lgan qator — yuboriladigan telefon yo'q.
	rows, err := s.DB.Query(ctx, `
		with c as (
			select id from notification_outbox
			where push_sent_at is null
			order by id
			limit $1
			for update skip locked
		), u as (
			update notification_outbox o set push_sent_at = now()
			from c where o.id = c.id
			returning o.id, o.user_id, o.message, o.link, o.created_at,
			          coalesce(to_jsonb(o)->>'audience', '') as audience -- ustun (2026-11-23) bo'lmasa ham xato bermaydi
		)
		select (select count(*)::int from u), u.id, t.token, u.message, u.link, u.created_at,
		       coalesce(to_jsonb(usr)->>'lang', ''), -- users.lang ustuni hali bo'lmasa ham xato bermaydi
		       coalesce((to_jsonb(t)->>'channels')::int, 0), -- push_tokens.channels (2026-11-17) bo'lmasa ham
		       u.audience, `+multiRoleSQL+`, -- bir nechta rolli odam (matn boshidagi belgi uchun)
		       coalesce(t.platform, '') -- android | ios: rangli logo faqat Android'ga (logo.go)
		from u left join push_tokens t on t.user_id = u.user_id
		left join users usr on usr.id = u.user_id
		order by u.id`, limit)
	if err != nil {
		return 0, nil, err
	}
	claimed := 0
	var list []Message
	for rows.Next() {
		var m Message
		var token *string
		if err := rows.Scan(&claimed, &m.ID, &token, &m.Text, &m.Link, &m.CreatedAt, &m.Lang, &m.Channels, &m.Audience, &m.MultiRole,
			&m.Platform); err != nil {
			rows.Close()
			return 0, nil, err
		}
		if token != nil {
			m.Token = *token
			list = append(list, m)
		}
	}
	return claimed, list, rows.Err()
}

func (s *PgStore) Release(ctx context.Context, ids []int64) error {
	_, err := s.DB.Exec(ctx, `update notification_outbox set push_sent_at = null where id = any($1)`, ids)
	return err
}

// MarkFailed — notification_outbox.push_error (2026-11-17). Ustun hali bo'lmasa xato qaytadi — faqat log'ga.
func (s *PgStore) MarkFailed(ctx context.Context, reasons map[int64]string) error {
	ids := make([]int64, 0, len(reasons))
	why := make([]string, 0, len(reasons))
	for id, r := range reasons {
		ids = append(ids, id)
		why = append(why, r)
	}
	_, err := s.DB.Exec(ctx, `
		update notification_outbox o set push_error = f.why
		from unnest($1::bigint[], $2::text[]) as f(id, why)
		where o.id = f.id`, ids, why)
	return err
}

func (s *PgStore) DeleteTokens(ctx context.Context, tokens []string) error {
	_, err := s.DB.Exec(ctx, `delete from push_tokens where token = any($1)`, tokens)
	return err
}

// SaveTickets — Expo qabul qilgan xabarlarning ticket id'lari (push_receipts, 2026-11-23).
func (s *PgStore) SaveTickets(ctx context.Context, tickets []TicketRef) error {
	ids := make([]string, len(tickets))
	outbox := make([]int64, len(tickets))
	tokens := make([]string, len(tickets))
	for i, t := range tickets {
		ids[i], outbox[i], tokens[i] = t.TicketID, t.OutboxID, t.Token
	}
	_, err := s.DB.Exec(ctx, `
		insert into push_receipts (ticket_id, outbox_id, token)
		select f.id, f.outbox, f.token from unnest($1::text[], $2::bigint[], $3::text[]) as f(id, outbox, token)
		on conflict (ticket_id) do nothing`, ids, outbox, tokens)
	return err
}

// PendingReceipts — tekshirilmagan va olderThan dan oldin yuborilgan ticket'lar (eng eskisi birinchi).
func (s *PgStore) PendingReceipts(ctx context.Context, olderThan time.Duration, limit int) ([]TicketRef, error) {
	rows, err := s.DB.Query(ctx, `
		select ticket_id, coalesce(outbox_id, 0), token, created_at from push_receipts
		where checked_at is null and created_at < now() - make_interval(secs => $1)
		order by created_at limit $2`, olderThan.Seconds(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TicketRef
	for rows.Next() {
		var t TicketRef
		if err := rows.Scan(&t.TicketID, &t.OutboxID, &t.Token, &t.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// SaveReceipts — natijalar. Rad etilganlar sababi notification_outbox.push_error ga ham (bo'sh bo'lsa) yoziladi —
// admin panel shu yerdan ko'radi. 7 kundan eski receipt'lar shu yerda tozalanadi (jadval o'smasin).
func (s *PgStore) SaveReceipts(ctx context.Context, results []ReceiptResult) error {
	ids := make([]string, len(results))
	status := make([]string, len(results))
	why := make([]string, len(results))
	for i, r := range results {
		ids[i], status[i], why[i] = r.TicketID, r.Status, r.Error
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		update push_receipts r set checked_at = now(), status = f.status, error = nullif(f.why, '')
		from unnest($1::text[], $2::text[], $3::text[]) as f(id, status, why)
		where r.ticket_id = f.id`, ids, status, why); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		update notification_outbox o set push_error = left('receipt: ' || r.error, 500)
		from push_receipts r
		where r.ticket_id = any($1) and r.status = 'error' and r.outbox_id = o.id and o.push_error is null`, ids); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `delete from push_receipts where created_at < now() - interval '7 days'`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// HasPendingReceipts — hali tekshirilmagan ticket bormi.
func (s *PgStore) HasPendingReceipts(ctx context.Context) (bool, error) {
	var ok bool
	err := s.DB.QueryRow(ctx, `select exists (select 1 from push_receipts where checked_at is null)`).Scan(&ok)
	return ok, err
}
