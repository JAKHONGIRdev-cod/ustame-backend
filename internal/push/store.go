package push

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

// PgStore — Store'ning Neon (Postgres) dagi amalga oshirilishi.
// Jadvallar: notification_outbox (push_sent_at, link), push_tokens (sql/app.sql).
type PgStore struct {
	DB *pgxpool.Pool
}

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
			returning o.id, o.user_id, o.message, o.link, o.created_at
		)
		select (select count(*)::int from u), u.id, t.token, u.message, u.link, u.created_at
		from u left join push_tokens t on t.user_id = u.user_id
		order by u.id`, limit)
	if err != nil {
		return 0, nil, err
	}
	claimed := 0
	var list []Message
	for rows.Next() {
		var m Message
		var token *string
		if err := rows.Scan(&claimed, &m.ID, &token, &m.Text, &m.Link, &m.CreatedAt); err != nil {
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

func (s *PgStore) DeleteTokens(ctx context.Context, tokens []string) error {
	_, err := s.DB.Exec(ctx, `delete from push_tokens where token = any($1)`, tokens)
	return err
}
