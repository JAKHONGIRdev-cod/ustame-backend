package push

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PgStore — Store'ning Neon (Postgres) dagi amalga oshirilishi.
// Jadvallar: notification_outbox (push_sent_at, link), push_tokens (sql/app.sql).
type PgStore struct {
	DB *pgxpool.Pool
}

func (s *PgStore) Claim(ctx context.Context, limit int) ([]Message, error) {
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
		select u.id, t.token, u.message, u.link, u.created_at
		from u join push_tokens t on t.user_id = u.user_id
		order by u.id`, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (Message, error) {
		var m Message
		err := row.Scan(&m.ID, &m.Token, &m.Text, &m.Link, &m.CreatedAt)
		return m, err
	})
}

func (s *PgStore) Release(ctx context.Context, ids []int64) error {
	_, err := s.DB.Exec(ctx, `update notification_outbox set push_sent_at = null where id = any($1)`, ids)
	return err
}

func (s *PgStore) DeleteTokens(ctx context.Context, tokens []string) error {
	_, err := s.DB.Exec(ctx, `delete from push_tokens where token = any($1)`, tokens)
	return err
}
