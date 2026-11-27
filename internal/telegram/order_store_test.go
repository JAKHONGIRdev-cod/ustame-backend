package telegram

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestPgOrderStore — PgStore'ning «Usta chaqirish» SQL'i haqiqiy Postgres'da. Faqat USTAME_PG_TEST_URL berilganda
// va u lokal manzil bo'lsa ishlaydi (lokal PGlite: usta-api sxemasi + seed: Chilonzor/Santexnik usta, admin,
// bloklangan foydalanuvchi). Prod bazada hech qachon ishga tushmaydi — test foydalanuvchi va e'lonlar yaratadi.
func TestPgOrderStore(t *testing.T) {
	raw := os.Getenv("USTAME_PG_TEST_URL")
	if raw == "" {
		t.Skip("USTAME_PG_TEST_URL berilmagan")
	}
	if u, err := url.Parse(raw); err != nil || (u.Hostname() != "127.0.0.1" && u.Hostname() != "localhost") {
		t.Fatalf("USTAME_PG_TEST_URL faqat lokal baza bo'lishi kerak (127.0.0.1/localhost), berilgan: %q", hostOf(raw))
	}
	ctx := context.Background()
	cfg, err := pgxpool.ParseConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	// PGlite socket bitta sessiyani ulanishlar orasida saqlaydi: nomli tayyorlangan so'rovlar keyingi ishga
	// tushirishda «already exists» beradi — testda keshsiz rejim
	cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeExec
	db, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	s := &PgStore{DB: db}
	// Har ishga tushirishda yangi raqamlar: baza qayta ishga tushirilmasa ham oldingi e'lonlar (takroriy, kunlik
	// chegara) xalaqit bermaydi
	run := time.Now().UnixNano() % 1e6
	newPhone := func(n int64) string { return fmt.Sprintf("99891%06d%d", run, n) }
	phone, chat := newPhone(1), 700000000+run
	count := func(q string, args ...any) int {
		t.Helper()
		var n int
		if err := db.QueryRow(ctx, q, args...).Scan(&n); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		return n
	}

	// Yangi mijoz: yaratiladi, chat ulanadi, ism Telegram'dan, ro'yxatdan o'tish manbasi havoladan
	if err := s.EnsureClient(ctx, chat, phone, "Ali Valiyev", Attribution{Source: "Instagram", Campaign: "nov25"}); err != nil {
		t.Fatalf("EnsureClient: %v", err)
	}
	if got, err := s.KnownLoginPhone(ctx, chat); err != nil || got != phone {
		t.Fatalf("KnownLoginPhone: %q %v", got, err)
	}
	var name, signup string
	var tgChat int64
	db.QueryRow(ctx, `select full_name, telegram_chat_id, signup_source::text from users where phone = $1`, phone).
		Scan(&name, &tgChat, &signup)
	if name != "Ali Valiyev" || tgChat != chat ||
		signup != `{"medium": "telegram_bot", "source": "instagram", "campaign": "nov25"}` {
		t.Fatalf("users: %q %d %s", name, tgChat, signup)
	}
	// Ism va manba bor bo'lsa ustidan yozilmaydi
	if err := s.EnsureClient(ctx, chat, phone, "Boshqa Ism", Attribution{Source: "facebook"}); err != nil {
		t.Fatal(err)
	}
	db.QueryRow(ctx, `select full_name, signup_source::text from users where phone = $1`, phone).Scan(&name, &signup)
	if name != "Ali Valiyev" || signup != `{"medium": "telegram_bot", "source": "instagram", "campaign": "nov25"}` {
		t.Fatalf("ism/manba o'zgarib ketdi: %q %s", name, signup)
	}
	// Havolasiz (menyudan) kelgan yangi mijoz — manba telegram_bot
	if err := s.EnsureClient(ctx, chat+3, newPhone(3), "", Attribution{}); err != nil {
		t.Fatal(err)
	}
	db.QueryRow(ctx, `select signup_source::text from users where phone = $1`, newPhone(3)).Scan(&signup)
	if signup != `{"medium": "telegram_bot", "source": "telegram_bot"}` {
		t.Fatalf("menyudan kelgan manba: %s", signup)
	}

	// E'lon: joylashuv va rasm bilan; mos ustaga xabar navbatga tushadi
	o := &OrderDraft{Category: "Santexnik", District: "Chilonzor", Description: "Hammomdagi trubadan suv oqyapti. Tezroq",
		Address: "Qatortol ko'chasi, 12-uy", Location: &Location{Latitude: 41.28, Longitude: 69.2}, Urgency: "today"}
	jpeg := []byte{0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3}
	res, err := s.PostOrder(ctx, phone, o, jpeg, false)
	if err != nil || res.Duplicate || res.Providers != 1 || res.Admins != 0 {
		t.Fatalf("PostOrder: %+v %v", res, err)
	}
	var title, urgency, address string
	var hasPhoto bool
	var lat *float64
	if err := db.QueryRow(ctx, `
		select j.title, j.urgency, j.has_photo, a.address, a.lat from jobs j join job_addresses a on a.job_id = j.id
		where j.id = $1::uuid`, res.JobID).Scan(&title, &urgency, &hasPhoto, &address, &lat); err != nil {
		t.Fatal(err)
	}
	if title != "Hammomdagi trubadan suv oqyapti" || urgency != "today" || !hasPhoto || address != o.Address ||
		lat == nil || *lat != 41.28 {
		t.Fatalf("jobs: %q %q rasm=%v %q %v", title, urgency, hasPhoto, address, lat)
	}
	if n := count(`select count(*)::int from notification_outbox o join users u on u.id = o.user_id
		where u.phone = '998900000077' and o.link = '/job/' || $1`, res.JobID); n != 1 {
		t.Fatalf("ustaga xabar: %d", n)
	}

	// 1-band: xuddi shu e'lon qayta yuborilsa — yangisi yaratilmaydi, o'sha e'lon qaytadi, ustaga ikkinchi xabar yo'q
	jobsBefore := count(`select count(*)::int from jobs`)
	again, err := s.PostOrder(ctx, phone, o, jpeg, false)
	if err != nil || !again.Duplicate || again.JobID != res.JobID || count(`select count(*)::int from jobs`) != jobsBefore {
		t.Fatalf("takroriy: %+v %v", again, err)
	}
	if n := count(`select count(*)::int from notification_outbox where link = '/job/' || $1`, res.JobID); n != 1 {
		t.Fatalf("takroriyda ustaga yana xabar: %d", n)
	}

	// 3-band: sinov (dry-run) — hammasi bajariladi, lekin e'lon, rasm va xabarlar saqlanmaydi
	outboxBefore := count(`select count(*)::int from notification_outbox`)
	filesBefore := count(`select count(*)::int from files`)
	test := *o
	test.Description = "Sinov: oshxonadagi kran oqyapti"
	dry, err := s.PostOrder(ctx, phone, &test, jpeg, true)
	if err != nil || dry.Duplicate || dry.JobID == "" || dry.Providers != 1 {
		t.Fatalf("dry-run: %+v %v", dry, err)
	}
	if count(`select count(*)::int from jobs where id = $1::uuid`, dry.JobID) != 0 ||
		count(`select count(*)::int from jobs`) != jobsBefore ||
		count(`select count(*)::int from notification_outbox`) != outboxBefore ||
		count(`select count(*)::int from files`) != filesBefore {
		t.Fatal("dry-run bazada iz qoldirdi")
	}
	// Bazada yo'q sinov raqami ham tekshiriladi va foydalanuvchi yaratilmaydi
	if _, err := s.PostOrder(ctx, newPhone(9), &test, nil, true); err != nil {
		t.Fatalf("yangi raqam dry-run: %v", err)
	}
	if count(`select count(*)::int from users where phone = $1`, newPhone(9)) != 0 {
		t.Fatal("dry-run foydalanuvchi yaratdi")
	}

	// Mos usta yo'q — adminlarga xabar (sanaladi)
	o2 := &OrderDraft{Category: "Boshqa", District: "Bektemir", Description: "Eshik qulfini almashtirish kerak",
		Location: &Location{Latitude: 41.2, Longitude: 69.33}, Urgency: "flexible"}
	r2, err := s.PostOrder(ctx, phone, o2, nil, false)
	if err != nil || r2.Providers != 0 || r2.Admins != 1 {
		t.Fatalf("mos ustasiz e'lon: %+v %v", r2, err)
	}

	// Telefon raqami tavsifda — rad etiladi
	bad := *o2
	bad.Description = "Qo'ng'iroq qiling 90 123 45 67 raqamiga"
	var oe OrderError
	if _, err := s.PostOrder(ctx, phone, &bad, nil, false); !errors.As(err, &oe) || oe != "CONTACT_NOT_ALLOWED" {
		t.Fatalf("kontakt: %v", err)
	}

	// Kunlik chegara: 24 soatda 5 ta (dry-run va takroriylar hisobga kirmaydi)
	for i := 0; i < 3; i++ {
		next := *o2
		next.Description = fmt.Sprintf("Eshik qulfini almashtirish kerak, %d-eshik", i+1)
		if _, err := s.PostOrder(ctx, phone, &next, nil, false); err != nil {
			t.Fatalf("%d-e'lon: %v", i+3, err)
		}
	}
	sixth := *o2
	sixth.Description = "Oltinchi e'lon, boshqa ish"
	if _, err := s.PostOrder(ctx, phone, &sixth, nil, false); !errors.As(err, &oe) || oe != "ORDER_LIMIT" {
		t.Fatalf("chegara: %v", err)
	}

	// Bloklangan foydalanuvchi
	if err := s.EnsureClient(ctx, chat+2, "998900000066", "X", Attribution{}); !errors.Is(err, ErrBlocked) {
		t.Fatalf("bloklangan EnsureClient: %v", err)
	}
	if _, err := s.PostOrder(ctx, "998900000066", o2, nil, false); !errors.Is(err, ErrBlocked) {
		t.Fatalf("bloklangan PostOrder: %v", err)
	}

	// 4-band: reklama tashrifi — manba va kampaniya tozalanib yoziladi
	if err := s.TrackOrderVisit(ctx, Attribution{Source: "Instagram-Ads", Campaign: "Nov25_Toshkent"}); err != nil {
		t.Fatalf("TrackOrderVisit: %v", err)
	}
	var src, medium, campaign, landing string
	db.QueryRow(ctx, `select source, medium, coalesce(campaign, ''), landing from visit_sources order by id desc limit 1`).
		Scan(&src, &medium, &campaign, &landing)
	if src != "instagram-ads" || medium != "telegram_bot" || campaign != "nov25_toshkent" || landing != "tg-order" {
		t.Fatalf("visit_sources: %q %q %q %q", src, medium, campaign, landing)
	}
	if err := s.TrackOrderVisit(ctx, Attribution{}); err != nil {
		t.Fatal(err)
	}
	db.QueryRow(ctx, `select source, coalesce(campaign, '') from visit_sources order by id desc limit 1`).Scan(&src, &campaign)
	if src != "telegram_bot" || campaign != "" {
		t.Fatalf("manbasiz tashrif: %q %q", src, campaign)
	}

	// RememberChat (botda o'z raqamini yuborgan chat): chat raqam egasiga o'tadi, eskisidan uziladi
	if err := s.RememberChat(ctx, chat+5, phone); err != nil {
		t.Fatalf("RememberChat: %v", err)
	}
	if got, _ := s.KnownLoginPhone(ctx, chat+5); got != phone {
		t.Fatalf("yangi chat tanilmadi: %q", got)
	}
	if got, _ := s.KnownLoginPhone(ctx, chat); got != "" {
		t.Fatalf("eski chat uzilmadi: %q", got)
	}
	// Bazada yo'q raqam — hisob yaratilmaydi; bloklangan foydalanuvchi — bog'lanmaydi
	if err := s.RememberChat(ctx, chat+6, newPhone(7)); err != nil {
		t.Fatal(err)
	}
	if count(`select count(*)::int from users where phone = $1`, newPhone(7)) != 0 {
		t.Fatal("RememberChat hisob yaratdi")
	}
	if err := s.RememberChat(ctx, chat+7, "998900000066"); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.KnownLoginPhone(ctx, chat+7); got != "" {
		t.Fatalf("bloklangan foydalanuvchi tanildi: %q", got)
	}
}

// hostOf — xato xabarida parol ko'rinmasin
func hostOf(raw string) string {
	if u, err := url.Parse(raw); err == nil {
		return u.Host
	}
	return "?"
}
