package push

import (
	"context"
	"net/url"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestPgStoreClaimPlatform — Claim haqiqiy Postgres'da: har token o'z platformasi bilan qaytadi (rangli logo faqat
// Android'ga), tokeni yo'q foydalanuvchining xabari faqat belgilanadi. Faqat USTAME_PG_TEST_URL lokal manzil bo'lsa
// ishlaydi (PGlite: usta-api sxemasi) — prod bazada hech qachon: xabarlarni "yuborildi" deb belgilaydi.
func TestPgStoreClaimPlatform(t *testing.T) {
	raw := os.Getenv("USTAME_PG_TEST_URL")
	if raw == "" {
		t.Skip("USTAME_PG_TEST_URL berilmagan")
	}
	if u, err := url.Parse(raw); err != nil || (u.Hostname() != "127.0.0.1" && u.Hostname() != "localhost") {
		t.Fatal("USTAME_PG_TEST_URL faqat lokal baza bo'lishi kerak (127.0.0.1/localhost)")
	}
	ctx := context.Background()
	cfg, err := pgxpool.ParseConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeExec // PGlite socket: nomli so'rovlarsiz
	db, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	var withTokens, noToken string
	if err := db.QueryRow(ctx, `insert into users (phone, full_name) values ('998900000501', 'Push Sinov') returning id`).
		Scan(&withTokens); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(ctx, `insert into users (phone, full_name) values ('998900000502', 'Tokensiz') returning id`).
		Scan(&noToken); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `insert into push_tokens (token, user_id, platform, channels) values
		('ExponentPushToken[androidtoken01]', $1, 'android', 1),
		('ExponentPushToken[iostoken000001]', $1, 'ios', 0)`, withTokens); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `insert into notification_outbox (user_id, message, link) values
		($1, 'Yangi e''lon', '/job/1'), ($2, 'Tokensiz xabar', null)`, withTokens, noToken); err != nil {
		t.Fatal(err)
	}

	s := &PgStore{DB: db}
	claimed, list, err := s.Claim(ctx, 50)
	if err != nil {
		t.Fatalf("Claim: %v", err)
	}
	if claimed != 2 {
		t.Fatalf("claimed = %d, kutilgan 2 (tokensiz xabar ham belgilanadi)", claimed)
	}
	got := map[string]Message{}
	for _, m := range list {
		got[m.Token] = m
	}
	if len(list) != 2 {
		t.Fatalf("telefonlar = %d, kutilgan 2: %+v", len(list), list)
	}
	if a := got["ExponentPushToken[androidtoken01]"]; a.Platform != "android" || a.Channels != 1 || a.Text != "Yangi e'lon" {
		t.Fatalf("Android tokeni noto'g'ri: %+v", a)
	}
	if i := got["ExponentPushToken[iostoken000001]"]; i.Platform != "ios" || i.Channels != 0 {
		t.Fatalf("iOS tokeni noto'g'ri: %+v", i)
	}

	// Ikkinchi marta hech narsa olinmaydi — hammasi "yuborildi" deb belgilangan
	if claimed, list, err := s.Claim(ctx, 50); err != nil || claimed != 0 || len(list) != 0 {
		t.Fatalf("takroriy Claim: %d %v %v", claimed, list, err)
	}
	db.Exec(ctx, `delete from users where id in ($1, $2)`, withTokens, noToken)
}
