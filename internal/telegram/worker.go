package telegram

import (
	"context"
	"errors"
	"log"
	"strings"
	"sync"
	"time"
)

// Notification — notification_outbox'dan yuborish uchun olingan bitta xabar.
type Notification struct {
	ID        int64
	ChatID    *int64 // foydalanuvchi botga ulanmagan bo'lsa nil
	Text      string
	CreatedAt time.Time
}

// Store — bot ishlatadigan baza amallari (pgx'dagi amalga oshirilishi: store.go).
type Store interface {
	SaveBotUsername(ctx context.Context, username string) error
	LastUpdateID(ctx context.Context) (int64, error)
	SaveLastUpdateID(ctx context.Context, id int64) error
	// LinkChat — telegram_link_code shu kodga teng foydalanuvchiga chat'ni bog'laydi.
	LinkChat(ctx context.Context, code string, chatID int64) (bool, error)
	UnlinkChat(ctx context.Context, chatID int64) error
	// BeginLogin — start_code bo'yicha muddati o'tmagan, hali tasdiqlanmagan kirishni shu chat'ga bog'laydi.
	BeginLogin(ctx context.Context, code string, chatID int64) (bool, error)
	// CompleteLogin — shu chat'dagi oxirgi kutilayotgan kirishga tasdiqlangan raqamni yozadi.
	CompleteLogin(ctx context.Context, chatID int64, phone string) (bool, error)
	// ClaimNotifications — yuborilmagan xabarlarni "yuborildi" deb belgilab oladi
	// (ikki nusxa bir vaqtda ishlasa ham bir xabar ikki marta ketmasin).
	ClaimNotifications(ctx context.Context, limit int) ([]Notification, error)
	// ReleaseNotification — yuborib bo'lmagan xabarni keyinroq qayta urinish uchun qaytaradi.
	ReleaseNotification(ctx context.Context, id int64) error
}

// Worker — botning ikki vazifasi: Telegram'dan kelgan /start buyruqlarini qabul qilish
// va navbatdagi bildirishnomalarni yuborish.
type Worker struct {
	TG    *Client
	Store Store

	PollTimeout   int           // getUpdates kutish vaqti, soniya (standart 25)
	OutboxEvery   time.Duration // navbatni tekshirish oralig'i (standart 3 s)
	RetryDelay    time.Duration // xatodan keyin kutish (standart 5 s)
	MaxMessageAge time.Duration // shundan eski xabar yuborilmay tashlanadi (standart 24 soat)
}

const (
	msgLinked = "✅ Ustame bildirishnomalari ulandi. Yangi taklif, xabar va shartnoma yangiliklari shu yerga keladi.\n\n" +
		"O'chirish uchun: /stop yoki ilovada Profil → Telegram → Uzish."
	msgBadCode = "Havola eskirgan yoki noto'g'ri. Ilovada Profil → Telegram → «Botga ulanish» tugmasini qayta bosing."
	msgHello   = "Assalomu alaykum! Bu Ustame bildirishnomalar boti.\n\n" +
		"Ulash uchun ilovada Profil → Telegram → «Botga ulanish» tugmasini bosing."
	msgStopped = "Bildirishnomalar o'chirildi. Qayta ulash uchun ilovada «Botga ulanish» tugmasini bosing."

	// Telegram orqali kirish
	loginPrefix   = "login_" // t.me/<bot>?start=login_<kod>
	contactButton = "📱 Raqamni yuborish"

	msgLoginAsk       = "Ustame ilovasiga kirish uchun pastdagi «" + contactButton + "» tugmasini bosing."
	msgLoginBadCode   = "Kirish havolasi eskirgan. Ilovada «Telegram orqali kirish» tugmasini qayta bosing."
	msgLoginNotOwn    = "Faqat o'zingizning raqamingizni yuboring: pastdagi «" + contactButton + "» tugmasini bosing."
	msgLoginNotUz     = "Hozircha faqat O'zbekiston raqamlari (+998) bilan kirish mumkin."
	msgLoginNoSession = "Avval ilovada «Telegram orqali kirish» tugmasini bosing, keyin raqamingizni yuboring."
	msgLoginDone      = "✅ Raqamingiz tasdiqlandi. Ilovaga qayting — kirish avtomatik davom etadi.\n\n" +
		"Ustame bildirishnomalari ham shu yerga keladi. O'chirish uchun: /stop"
)

var (
	askContactKeyboard = map[string]any{
		"keyboard":          [][]map[string]any{{{"text": contactButton, "request_contact": true}}},
		"resize_keyboard":   true,
		"one_time_keyboard": true,
	}
	removeKeyboard = map[string]any{"remove_keyboard": true}
)

func (w *Worker) defaults() {
	if w.PollTimeout == 0 {
		w.PollTimeout = 25
	}
	if w.OutboxEvery == 0 {
		w.OutboxEvery = 3 * time.Second
	}
	if w.RetryDelay == 0 {
		w.RetryDelay = 5 * time.Second
	}
	if w.MaxMessageAge == 0 {
		w.MaxMessageAge = 24 * time.Hour
	}
}

// Run — ctx bekor qilinguncha ishlaydi.
func (w *Worker) Run(ctx context.Context) {
	w.defaults()

	// Bot nomini bazaga yozamiz: ilova get_telegram_link() orqali shu nomni oladi.
	for {
		me, err := w.TG.GetMe(ctx)
		if err == nil {
			if err := w.Store.SaveBotUsername(ctx, me.Username); err != nil {
				log.Printf("telegram: bot nomini saqlab bo'lmadi: %v", err)
			}
			log.Printf("telegram: @%s boti ishga tushdi", me.Username)
			break
		}
		log.Printf("telegram: getMe xato (token to'g'rimi?): %v", err)
		if !sleep(ctx, time.Minute) {
			return
		}
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); w.pollUpdates(ctx) }()
	go func() { defer wg.Done(); w.deliverLoop(ctx) }()
	wg.Wait()
}

func (w *Worker) pollUpdates(ctx context.Context) {
	offset, err := w.Store.LastUpdateID(ctx)
	if err != nil {
		log.Printf("telegram: last_update_id o'qilmadi: %v", err)
	}
	if offset > 0 {
		offset++
	}
	for ctx.Err() == nil {
		ups, err := w.TG.GetUpdates(ctx, offset, w.PollTimeout)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			// 409 — boshqa nusxa ham getUpdates qilyapti (masalan, deploy paytida)
			log.Printf("telegram: getUpdates: %v", err)
			sleep(ctx, w.RetryDelay)
			continue
		}
		for _, u := range ups {
			w.handleUpdate(ctx, u)
			offset = u.UpdateID + 1
		}
		if len(ups) > 0 {
			if err := w.Store.SaveLastUpdateID(ctx, offset-1); err != nil {
				log.Printf("telegram: last_update_id saqlanmadi: %v", err)
			}
		}
	}
}

func (w *Worker) handleUpdate(ctx context.Context, u Update) {
	m := u.Message
	if m == nil {
		return
	}
	chatID := m.Chat.ID
	if m.Contact != nil {
		if reply, markup := w.contactReply(ctx, m); reply != "" {
			w.send(ctx, chatID, reply, markup)
		}
		return
	}
	cmd, arg, _ := strings.Cut(strings.TrimSpace(m.Text), " ")
	cmd, _, _ = strings.Cut(cmd, "@") // "/start@UstameBot" ko'rinishi ham bo'ladi
	arg = strings.TrimSpace(arg)

	var reply string
	var markup any
	switch {
	case cmd == "/start" && strings.HasPrefix(arg, loginPrefix):
		if m.Chat.Type != "private" {
			return
		}
		ok, err := w.Store.BeginLogin(ctx, strings.TrimPrefix(arg, loginPrefix), chatID)
		switch {
		case err != nil:
			log.Printf("telegram: kirishni boshlashda xato: %v", err)
			return
		case ok:
			reply, markup = msgLoginAsk, askContactKeyboard
		default:
			reply = msgLoginBadCode
		}
	case cmd == "/start" && arg != "":
		ok, err := w.Store.LinkChat(ctx, arg, chatID)
		switch {
		case err != nil:
			log.Printf("telegram: ulashda xato: %v", err)
			return
		case ok:
			reply = msgLinked
		default:
			reply = msgBadCode
		}
	case cmd == "/stop":
		if err := w.Store.UnlinkChat(ctx, chatID); err != nil {
			log.Printf("telegram: uzishda xato: %v", err)
			return
		}
		reply = msgStopped
	default:
		reply = msgHello
	}
	w.send(ctx, chatID, reply, markup)
}

// contactReply — yuborilgan kontaktni tekshiradi va kirishni tasdiqlaydi. Bo'sh javob — jim turamiz.
func (w *Worker) contactReply(ctx context.Context, m *Message) (string, any) {
	if m.Chat.Type != "private" {
		return "", nil
	}
	// Forward qilingan yoki boshqa odamning kontakti: user_id yuboruvchiniki bilan mos kelmaydi
	if m.From == nil || m.Contact.UserID != m.From.ID {
		return msgLoginNotOwn, askContactKeyboard
	}
	phone, ok := uzPhone(m.Contact.PhoneNumber)
	if !ok {
		return msgLoginNotUz, removeKeyboard
	}
	ok, err := w.Store.CompleteLogin(ctx, m.Chat.ID, phone)
	switch {
	case err != nil:
		log.Printf("telegram: kirishni tasdiqlashda xato: %v", err)
		return "", nil
	case !ok:
		return msgLoginNoSession, removeKeyboard
	}
	return msgLoginDone, removeKeyboard
}

func (w *Worker) send(ctx context.Context, chatID int64, text string, markup any) {
	if err := w.TG.SendMessageMarkup(ctx, chatID, text, markup); err != nil {
		log.Printf("telegram: javob yuborilmadi: %v", err)
	}
}

// uzPhone: "+998 90 123-45-67" -> "998901234567". Telegram raqamni xalqaro ko'rinishda beradi.
func uzPhone(raw string) (string, bool) {
	d := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, raw)
	if len(d) == 12 && strings.HasPrefix(d, "998") {
		return d, true
	}
	return "", false
}

func (w *Worker) deliverLoop(ctx context.Context) {
	for ctx.Err() == nil {
		if wait := w.deliverOnce(ctx); !sleep(ctx, max(wait, w.OutboxEvery)) {
			return
		}
	}
}

// deliverOnce — bir partiya xabarni yuboradi; qaytargan vaqt — keyingi urinishgacha qo'shimcha kutish.
func (w *Worker) deliverOnce(ctx context.Context) time.Duration {
	list, err := w.Store.ClaimNotifications(ctx, 20)
	if err != nil {
		log.Printf("telegram: navbat o'qilmadi: %v", err)
		return w.RetryDelay
	}
	var wait time.Duration
	for i, n := range list {
		if n.ChatID == nil {
			continue // botga ulanmagan foydalanuvchi — xabar shunchaki "yuborilgan" qoladi
		}
		err := w.TG.SendMessage(ctx, *n.ChatID, n.Text)
		if err == nil {
			continue
		}
		var apiErr *APIError
		switch {
		case errors.As(err, &apiErr) && (apiErr.Code == 403 || isChatGone(apiErr)):
			// Foydalanuvchi botni bloklagan yoki chat yo'q — ulanishni uzamiz
			if err := w.Store.UnlinkChat(ctx, *n.ChatID); err != nil {
				log.Printf("telegram: uzishda xato: %v", err)
			}
		case errors.As(err, &apiErr) && apiErr.Code == 429:
			// Juda tez yuboryapmiz: shu va qolgan xabarlarni qaytarib, kutamiz
			for _, rest := range list[i:] {
				w.release(ctx, rest.ID)
			}
			return time.Duration(max(apiErr.RetryAfter, 1)) * time.Second
		case time.Since(n.CreatedAt) > w.MaxMessageAge:
			log.Printf("telegram: %d-xabar eskirdi, tashlab yuborildi: %v", n.ID, err)
		default:
			log.Printf("telegram: %d-xabar yuborilmadi, keyinroq qayta urinamiz: %v", n.ID, err)
			w.release(ctx, n.ID)
			wait = w.RetryDelay
		}
	}
	return wait
}

func (w *Worker) release(ctx context.Context, id int64) {
	if err := w.Store.ReleaseNotification(ctx, id); err != nil {
		log.Printf("telegram: %d-xabarni qaytarib bo'lmadi: %v", id, err)
	}
}

func isChatGone(e *APIError) bool {
	d := strings.ToLower(e.Description)
	return e.Code == 400 && (strings.Contains(d, "chat not found") || strings.Contains(d, "user is deactivated"))
}

// sleep — d kutadi; ctx bekor bo'lsa false qaytaradi.
func sleep(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}
