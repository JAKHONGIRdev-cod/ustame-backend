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
// backend chaqiradi.
//
// Neon bepul tarifida baza bo'sh paytda uxlashi kerak (oylik hisoblash soatlari), shuning uchun bazani
// o'zi tez-tez uyg'otmaydi: ishga tushganda, API faolligi signalida (baza baribir uyg'oq) — oxirgi
// ishdan kamida minGap o'tgan bo'lsa, va zaxira sifatida har `idle` da ishlaydi.
// afterRun — shartnoma yakunlanganda yoki zaxira ishda chaqiriladi (bildirishnoma ishchilarini shu
// uyg'onishning o'zida uyg'otish uchun). ctx bekor bo'lguncha ishlaydi.
func AutoApprove(ctx context.Context, db Querier, activity <-chan struct{}, minGap, idle time.Duration, afterRun func()) {
	run := func() int {
		var n int
		if err := db.QueryRow(ctx, `select public.auto_approve_overdue()`).Scan(&n); err != nil {
			if ctx.Err() == nil {
				log.Printf("auto-approve: %v", err)
			}
			return 0
		}
		if n > 0 {
			log.Printf("auto-approve: %d ta shartnoma avtomatik yakunlandi", n)
		}
		return n
	}
	notify := func() {
		if afterRun != nil {
			afterRun()
		}
	}

	if run() > 0 {
		notify()
	}
	last := time.Now()
	t := time.NewTimer(idle)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-activity:
			if time.Since(last) < minGap {
				continue
			}
			if run() > 0 {
				notify()
			}
		case <-t.C:
			run()
			notify() // baza hozir uyg'oq — navbatni ham shu paytda tekshirib olsin
		}
		last = time.Now()
		t.Reset(idle)
	}
}
