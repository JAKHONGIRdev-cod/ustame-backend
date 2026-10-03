package telegram

import (
	"cmp"
	"context"
	"errors"
	"slices"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PgStore — Store'ning Neon (Postgres) dagi amalga oshirilishi.
// Jadvallar: app_secrets, notification_outbox, users (usta-api/sql/app.sql).
type PgStore struct {
	DB *pgxpool.Pool
}

func (s *PgStore) SaveBotUsername(ctx context.Context, username string) error {
	_, err := s.DB.Exec(ctx, `update app_secrets set telegram_bot_username = $1 where id = 1`, username)
	return err
}

func (s *PgStore) LastUpdateID(ctx context.Context) (int64, error) {
	var id int64
	err := s.DB.QueryRow(ctx, `select telegram_last_update_id from app_secrets where id = 1`).Scan(&id)
	return id, err
}

func (s *PgStore) SaveLastUpdateID(ctx context.Context, id int64) error {
	_, err := s.DB.Exec(ctx, `update app_secrets set telegram_last_update_id = $1 where id = 1`, id)
	return err
}

func (s *PgStore) LinkChat(ctx context.Context, code string, chatID int64) (bool, error) {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)

	var userID string
	err = tx.QueryRow(ctx, `select id::text from users where telegram_link_code = $1 for update`, code).Scan(&userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	// telegram_chat_id unikal: shu Telegram akkaunt boshqa profilga ulangan bo'lsa, o'shandan uziladi
	if _, err := tx.Exec(ctx, `update users set telegram_chat_id = null where telegram_chat_id = $1 and id::text <> $2`,
		chatID, userID); err != nil {
		return false, err
	}
	// Kod bir martalik: keyingi ulanishda get_telegram_link() yangisini yaratadi
	if _, err := tx.Exec(ctx, `update users set telegram_chat_id = $1, telegram_link_code = null where id::text = $2`,
		chatID, userID); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

func (s *PgStore) UnlinkChat(ctx context.Context, chatID int64) error {
	_, err := s.DB.Exec(ctx, `update users set telegram_chat_id = null where telegram_chat_id = $1`, chatID)
	return err
}

func (s *PgStore) ClaimNotifications(ctx context.Context, limit int) ([]Notification, error) {
	rows, err := s.DB.Query(ctx, `
		with c as (
			select id from notification_outbox
			where sent_at is null
			order by id
			limit $1
			for update skip locked
		)
		update notification_outbox o set sent_at = now()
		from c, users u
		where o.id = c.id and u.id = o.user_id
		returning o.id, u.telegram_chat_id, o.message, o.created_at`, limit)
	if err != nil {
		return nil, err
	}
	list, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Notification, error) {
		var n Notification
		err := row.Scan(&n.ID, &n.ChatID, &n.Text, &n.CreatedAt)
		return n, err
	})
	if err != nil {
		return nil, err
	}
	// "returning" tartibni kafolatlamaydi — eskisidan boshlab yuboramiz
	slices.SortFunc(list, func(a, b Notification) int { return cmp.Compare(a.ID, b.ID) })
	return list, nil
}

func (s *PgStore) ReleaseNotification(ctx context.Context, id int64) error {
	_, err := s.DB.Exec(ctx, `update notification_outbox set sent_at = null where id = $1`, id)
	return err
}
