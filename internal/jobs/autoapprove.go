// Package jobs — server bilan birga ishlaydigan davriy vazifalar.
package jobs

import (
	"context"
	"log"
	"time"

	"github.com/jackc/pgx/v5"
)

// Querier — pgxpool.Pool'ning bizga kerakli qismi (testlarda soxtasi beriladi).
type Querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// AutoApprove — usta ishni topshirgach mijoz 48 soat ichida javob bermasa, ishni avtomatik qabul qiladi
// (sql/app.sql: auto_approve_overdue). Supabase'da buni pg_cron qilardi, Neon'da u yo'q — shuning uchun
// backend chaqiradi. Darhol bir marta, keyin har `every` da ishlaydi; ctx bekor bo'lguncha.
func AutoApprove(ctx context.Context, db Querier, every time.Duration) {
	run := func() {
		var n int
		if err := db.QueryRow(ctx, `select public.auto_approve_overdue()`).Scan(&n); err != nil {
			if ctx.Err() == nil {
				log.Printf("auto-approve: %v", err)
			}
			return
		}
		if n > 0 {
			log.Printf("auto-approve: %d ta shartnoma avtomatik yakunlandi", n)
		}
	}

	run()
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			run()
		}
	}
}
