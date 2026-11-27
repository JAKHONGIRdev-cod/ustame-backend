package telegram

import (
	"context"
	"errors"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// OrderStore — «Usta chaqirish» oqimining baza amallari (order.go). Yangi jadval yo'q: e'lon ilovadagi kabi
// post_job orqali, foydalanuvchi nomidan (auth.set_request_user) joylanadi — barcha tekshiruvlar va ustalarga
// xabar (trg_notify_new_job, trg_notify_urgent_job) o'zgarishsiz ishlaydi.
type OrderStore interface {
	// EnsureClient — raqam bo'yicha foydalanuvchini topadi yoki yaratadi, chat'ni unga bog'laydi (bildirishnomalar
	// va keyingi kirishlar shu Telegram'ga), ismi bo'sh bo'lsa Telegram'dagi ismni, yangi foydalanuvchiga esa
	// ro'yxatdan o'tish manbasini (signup_source) yozadi. Bloklangan — ErrBlocked.
	EnsureClient(ctx context.Context, chatID int64, phone, name string, src Attribution) error
	// PostOrder — e'lonni shu raqamli foydalanuvchi nomidan joylaydi; joylashuv va rasm (bo'lsa) ham qo'shiladi.
	// Xuddi shu e'lon 10 daqiqa ichida bo'lsa — yangisi yaratilmaydi (Duplicate). dryRun — hammasi bajarilib,
	// oxirida bekor qilinadi (sinov raqamlari: e'lon saqlanmaydi, ustalarga xabar ketmaydi).
	// SQL tekshiruvi rad etsa — OrderError (masalan CONTACT_NOT_ALLOWED, ORDER_LIMIT).
	PostOrder(ctx context.Context, phone string, o *OrderDraft, photo []byte, dryRun bool) (OrderResult, error)
	// TrackOrderVisit — reklama havolasidan kelgan tashrif (visit_sources; admin «Trafik manbalari»da ko'rinadi).
	TrackOrderVisit(ctx context.Context, src Attribution) error
}

// OrderResult — PostOrder natijasi
type OrderResult struct {
	JobID     string
	Duplicate bool // xuddi shu e'lon (kasb, tuman, tavsif) 10 daqiqa ichida joylangan — JobID o'shaniki
	Providers int  // e'lon haqida xabar navbatga tushgan ustalar
	Admins    int  // adminlarga xabar (masalan, mos usta topilmasa)
}

// ErrBlocked — foydalanuvchi bloklangan yoki hisobi o'chirilgan
var ErrBlocked = errors.New("account blocked")

// OrderError — SQL funksiyasi qaytargan xato kodi (post_job: INVALID_TITLE, CONTACT_NOT_ALLOWED, ...)
type OrderError string

func (e OrderError) Error() string { return string(e) }

// orderDailyLimit — bitta foydalanuvchi bot orqali 24 soatda shuncha e'londan ko'p bera olmaydi (spamdan himoya)
const orderDailyLimit = 5

// botMedium — bot orqali kelganlarning manba turi (visit_sources.medium, users.signup_source.medium)
const botMedium = "telegram_bot"

var sqlErrorCode = regexp.MustCompile(`^[A-Z][A-Z_]+$`)

func (s *PgStore) EnsureClient(ctx context.Context, chatID int64, phone, name string, src Attribution) error {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var uid string
	var blocked bool
	if err := tx.QueryRow(ctx, `
		insert into users (phone) values ($1)
		on conflict (phone) do update set phone = excluded.phone
		returning id::text, blocked_at is not null or deleted_at is not null`, phone).Scan(&uid, &blocked); err != nil {
		return err
	}
	if blocked {
		return ErrBlocked
	}
	// api/telegram_login.go dagi kabi: bildirishnomalar shu chat'ga (telegram_chat_id unikal — boshqa profildan
	// uziladi) va raqam shu chat'dan tasdiqlangan (keyingi kirishda bot raqamni qayta so'ramaydi)
	if _, err := tx.Exec(ctx, `update users set telegram_chat_id = null where telegram_chat_id = $1 and id::text <> $2`,
		chatID, uid); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `update users set telegram_chat_id = $1 where id = $2::uuid`, chatID, uid); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		update users set telegram_login_chat_id = case when id = $2::uuid then $1::bigint end
		where id = $2::uuid or telegram_login_chat_id = $1::bigint`, chatID, uid); err != nil {
		return err
	}
	if name = strings.TrimSpace(name); name != "" {
		if _, err := tx.Exec(ctx, `update users set full_name = $2 where id = $1::uuid and btrim(full_name) = ''`,
			uid, truncate(name, 60)); err != nil {
			return err
		}
	}
	// Ro'yxatdan o'tish manbasi — set_my_source bilan bir xil qoida: bir marta, ro'yxatdan o'tgan kuni
	if _, err := tx.Exec(ctx, `
		update users set signup_source = jsonb_strip_nulls(jsonb_build_object(
		    'source', coalesce(public._clean_source($2, 40), 'telegram_bot'), 'medium', $4::text,
		    'campaign', public._clean_source($3, 60)))
		where id = $1::uuid and signup_source is null and created_at > now() - interval '1 day'`,
		uid, src.Source, src.Campaign, botMedium); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *PgStore) PostOrder(ctx context.Context, phone string, o *OrderDraft, photo []byte, dryRun bool) (OrderResult, error) {
	var res OrderResult
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return res, err
	}
	defer tx.Rollback(ctx) // dryRun'da commit yo'q — hammasi shu yerda bekor bo'ladi

	if dryRun {
		// Sinov raqami bazada bo'lmasa ham tekshiruv o'tsin (bu ham bekor qilinadi)
		if _, err := tx.Exec(ctx, `insert into users (phone) values ($1) on conflict (phone) do nothing`, phone); err != nil {
			return res, err
		}
	}
	var uid string
	var tv, today int
	err = tx.QueryRow(ctx, `
		select u.id::text, u.token_version,
		       (select count(*)::int from jobs j where j.client_id = u.id and j.created_at > now() - interval '24 hours')
		from users u where u.phone = $1 and u.blocked_at is null and u.deleted_at is null`, phone).Scan(&uid, &tv, &today)
	if errors.Is(err, pgx.ErrNoRows) {
		return res, ErrBlocked
	}
	if err != nil {
		return res, err
	}
	// Takroriy e'lon: «E'lon qilish» qayta bosilgan, javob yetib bormay qayta urinilgan yoki ikkinchi nusxa
	err = tx.QueryRow(ctx, `
		select id::text from jobs
		where client_id = $1::uuid and category = $2 and district = $3 and description = btrim($4)
		  and created_at > now() - interval '10 minutes'
		order by created_at desc limit 1`, uid, o.Category, o.District, o.Description).Scan(&res.JobID)
	if err == nil {
		res.Duplicate = true
		return res, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return res, err
	}
	if today >= orderDailyLimit {
		return res, OrderError("ORDER_LIMIT")
	}
	if _, err := tx.Exec(ctx, `select auth.set_request_user($1::uuid, $2)`, uid, tv); err != nil {
		return res, sqlError(err)
	}
	if err := tx.QueryRow(ctx, `
		select public.post_job(p_category => $1, p_district => $2, p_title => $3, p_description => $4,
		                       p_address => $5, p_budget => null, p_urgency => $6)::text`,
		o.Category, o.District, o.Title(), o.Description, o.AddressText(), o.Urgency).Scan(&res.JobID); err != nil {
		return res, sqlError(err)
	}
	if o.Location != nil {
		if _, err := tx.Exec(ctx, `select public.set_job_location($1::uuid, $2, $3)`,
			res.JobID, o.Location.Latitude, o.Location.Longitude); err != nil {
			return res, sqlError(err)
		}
	}
	if len(photo) > 0 {
		// Ilovadagi e'lon rasmi bilan bir xil joy: job-photos/<e'lon>/photo.jpg (api/files.go)
		if _, err := tx.Exec(ctx, `
			insert into files (bucket, path, content_type, data) values ('job-photos', $1 || '/photo.jpg', 'image/jpeg', $2)
			on conflict (bucket, path) do update set data = excluded.data, updated_at = now()`, res.JobID, photo); err != nil {
			return res, err
		}
		if _, err := tx.Exec(ctx, `select public.set_job_photo_uploaded($1::uuid)`, res.JobID); err != nil {
			return res, sqlError(err)
		}
	}
	// Triggerlar shu tranzaksiyada navbatga qo'ygan xabarlar (created_at = now() — tranzaksiya vaqti):
	// ustalarga — e'lon havolasi bilan, adminlarga — /admin/... havolasi bilan (notify_new_job, notify_urgent_job)
	if err := tx.QueryRow(ctx, `
		select count(*) filter (where link = '/job/' || $1)::int, count(*) filter (where link like '/admin/%')::int
		from notification_outbox where created_at = now()`, res.JobID).Scan(&res.Providers, &res.Admins); err != nil {
		return res, err
	}
	if dryRun {
		return res, nil // defer tx.Rollback — e'lon, rasm va xabarlar saqlanmaydi
	}
	return res, tx.Commit(ctx)
}

func (s *PgStore) TrackOrderVisit(ctx context.Context, src Attribution) error {
	_, err := s.DB.Exec(ctx, `
		insert into visit_sources (source, medium, campaign, landing)
		values (coalesce(public._clean_source($1, 40), 'telegram_bot'), $3, public._clean_source($2, 60), 'tg-order')`,
		src.Source, src.Campaign, botMedium)
	return err
}

// sqlError — SQL funksiyasining "raise exception 'KOD'" xatosini OrderError'ga aylantiradi
func sqlError(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && sqlErrorCode.MatchString(pgErr.Message) {
		return OrderError(pgErr.Message)
	}
	return err
}
