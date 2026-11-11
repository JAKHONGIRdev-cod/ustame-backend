package telegram

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log"
	"math/big"
	"strings"
	"sync"
	"time"

	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/auth"
	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/cyrillic"
)

// Notification — notification_outbox'dan yuborish uchun olingan bitta xabar.
type Notification struct {
	ID        int64
	ChatID    *int64 // foydalanuvchi botga ulanmagan bo'lsa nil
	Text      string
	Lang      string // users.lang: "uzc" bo'lsa matn kirillga o'giriladi
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
	// KnownLoginPhone — shu chat'dan avval Telegram orqali kirib raqami tasdiqlangan (bloklanmagan) foydalanuvchi
	// raqami; bo'lmasa "". Faqat bildirishnoma uchun ulangan chat hisobga olinmaydi.
	KnownLoginPhone(ctx context.Context, chatID int64) (string, error)
	// IssueLoginCode — raqamga bir martalik kirish kodini yozadi (otp_codes; saytdagi /api/auth/verify tekshiradi).
	// false — shu raqamga oxirgi soatda juda ko'p kod berilgan.
	IssueLoginCode(ctx context.Context, phone, codeHash string) (bool, error)
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

	PollTimeout int // getUpdates kutish vaqti, soniya (standart 25)
	// Wake — API navbatga xabar qo'shilgan bo'lishi mumkin bo'lganda signal beradi (internal/wakeup).
	// Navbat doimiy so'ralmaydi: Neon bo'sh paytda uxlab, oylik hisoblash soatlarini tejasin.
	Wake          <-chan struct{}
	IdlePoll      time.Duration // signalsiz zaxira tekshiruv oralig'i (standart 6 soat)
	RetryDelay    time.Duration // xatodan keyin kutish (standart 5 s)
	MaxMessageAge time.Duration // shundan eski xabar yuborilmay tashlanadi (standart 24 soat)
	// OTPSecret — SMS kodlari bilan bir xil kalit (config.OTPSecret): bot bergan kod /api/auth/verify'da tekshiriladi.
	// Bo'sh bo'lsa bot kod bermaydi (faqat havola orqali kirish).
	OTPSecret []byte
	// SiteURL — saytga qaytish tugmasi uchun (standart https://ustame.com)
	SiteURL string

	// loginLang — kirish havolasidan kelgan til (chat_id → "uzc"): ilovada kirill tanlangan bo'lsa,
	// kirish oqimidagi javoblar (kontakt yuborilgandan keyingisi ham) kirillda.
	loginLang sync.Map
	// loginApp — kirish Android ilovadan boshlangan (chat_id → true): saytga qaytish tugmasi ko'rsatilmaydi
	loginApp sync.Map
}

// Kirish havolasi oxiridagi belgilar (api/telegram_login.go): login_<kod>[_a][_c]
const (
	loginAppSuffix = "_a" // ilovadan (brauzerdan emas) boshlangan
	loginCyrSuffix = "_c" // ilovada o'zbek kirill tanlangan
)

// reply — kirish oqimidagi javob, chat tiliga moslab
func (w *Worker) reply(chatID int64, text string) string {
	if lang, ok := w.loginLang.Load(chatID); ok {
		return cyrillic.For(lang.(string), text)
	}
	return text
}

const (
	msgLinked = "✅ Ustame bildirishnomalari ulandi. Yangi taklif, xabar va shartnoma yangiliklari shu yerga keladi.\n\n" +
		"O'chirish uchun: /stop yoki ilovada Profil → Telegram → Uzish."
	msgBadCode = "Havola eskirgan yoki noto'g'ri. Ilovada Profil → Telegram → «Botga ulanish» tugmasini qayta bosing."
	msgHello   = "Assalomu alaykum! Bu Ustame boti.\n\n" +
		"Ustame'ga kirish uchun pastdagi «" + contactButton + "» tugmasini bosing — kirish kodini yuboramiz 👇\n\n" +
		"Tugma ko'rinmasa, xabar yozish joyi yonidagi klaviatura (🎛) belgisini bosing."
	// msgHelloNoCode — kod berish o'chiq (OTPSecret yo'q) yoki guruh chati: oddiy /start javobi
	msgHelloNoCode = "Assalomu alaykum! Bu Ustame bildirishnomalar boti.\n\n" +
		"Ulash uchun ilovada Profil → Telegram → «Botga ulanish» tugmasini bosing."
	msgStopped = "Bildirishnomalar o'chirildi. Qayta ulash uchun ilovada «Botga ulanish» tugmasini bosing."

	// Telegram orqali kirish
	loginPrefix   = "login_" // t.me/<bot>?start=login_<kod>
	contactButton = "📱 Raqamni yuborish"

	msgLoginAsk = "Ustame ilovasiga kirish uchun pastdagi «" + contactButton + "» tugmasini bosing 👇\n\n" +
		"Tugma ko'rinmasa, xabar yozish joyi yonidagi klaviatura (🎛) belgisini bosing."
	msgLoginBadCode   = "Kirish havolasi eskirgan. Ilovada «Telegram orqali kirish» tugmasini qayta bosing."
	msgLoginNotOwn    = "Faqat o'zingizning raqamingizni yuboring: pastdagi «" + contactButton + "» tugmasini bosing."
	msgLoginNotUz     = "Hozircha faqat O'zbekiston raqamlari (+998) bilan kirish mumkin."
	msgLoginNoSession = "Avval ilovada «Telegram orqali kirish» tugmasini bosing, keyin raqamingizni yuboring."
	msgLoginDone      = "✅ Raqamingiz tasdiqlandi. Ilovaga qayting — kirish avtomatik davom etadi.\n\n" +
		"Ustame bildirishnomalari ham shu yerga keladi. O'chirish uchun: /stop"
	msgLoginKnown = "✅ Siz bu Telegram orqali avval tasdiqlangansiz — raqamni qayta yuborish shart emas. " +
		"Ilovaga qayting — kirish avtomatik davom etadi."
	// Saytdan kelganlarga: tugma bir martalik kod bilan saytni ochadi va darhol kiritadi (qaysi brauzerda ochilsa ham)
	btnBack  = "↩️ Ustame'ga qaytish"
	btnLogin = "🔑 Ustame'ga kirish"

	msgLoginKnownLink = "✅ Siz bu Telegram orqali avval tasdiqlangansiz — raqamni qayta yuborish shart emas.\n\n" +
		"Pastdagi «" + btnBack + "» tugmasini bosing — darhol kirasiz. " +
		"Yoki o'zingiz qayting: kirish o'zi davom etadi.\n\nKirish kodi (kerak bo'lsa): %s"
	msgLoginDoneLink = "✅ Raqamingiz tasdiqlandi.\n\n" +
		"Pastdagi «" + btnBack + "» tugmasini bosing — darhol kirasiz. " +
		"Yoki o'zingiz qayting: kirish o'zi davom etadi.\n\nKirish kodi (kerak bo'lsa): %s\n\n" +
		"Ustame bildirishnomalari ham shu yerga keladi. O'chirish uchun: /stop"
	msgLoginCodeLink = "🔑 Ustame'ga kirish kodingiz: %s\n\n" +
		"Pastdagi «" + btnLogin + "» tugmasini bosing — darhol kirasiz.\n\n" +
		"Yoki saytda yoki ilovada «Telegram orqali kirish» → «Telegram kodi bilan kirish» ni bosing va raqamingiz bilan " +
		"shu kodni kiriting. Kod 10 daqiqa amal qiladi.\n\nKodni hech kimga bermang."

	// Ilovadan kelganlarga (Telegram tugmasi ilovani ocha olmaydi — faqat veb-havola): ilovaga o'zi qaytadi
	msgLoginKnownCode = "✅ Siz bu Telegram orqali avval tasdiqlangansiz — raqamni qayta yuborish shart emas. " +
		"Ustame ilovasiga qayting — kirish o'zi davom etadi.\n\n" +
		"O'zi kirmasa, «Telegram kodi bilan kirish» ni bosing va shu kodni kiriting: %s"
	// msgLoginDoneCode — tasdiqlangach zaxira kod ham: ilova yopilib qolgan bo'lsa ham kiradi
	msgLoginDoneCode = "✅ Raqamingiz tasdiqlandi. Ustame ilovasiga qayting — kirish o'zi davom etadi.\n\n" +
		"O'zi kirmasa, «Telegram kodi bilan kirish» ni bosing va shu kodni kiriting: %s\n\n" +
		"Ustame bildirishnomalari ham shu yerga keladi. O'chirish uchun: /stop"
	// msgLoginCode — kutilayotgan kirish yo'q (eskirgan havola bilan ilovadan kelgan): kirish kodi
	msgLoginCode = "🔑 Ustame'ga kirish kodingiz: %s\n\n" +
		"Ilovada «Telegram orqali kirish» → «Telegram kodi bilan kirish» ni bosing, raqamingiz va shu kodni kiriting " +
		"(yoki «Telegram orqali kirish» tugmasini qayta bosing). Kod 10 daqiqa amal qiladi.\n\nKodni hech kimga bermang."
	msgLoginExpiredAsk = "Bu kirish havolasi eskirgan, lekin muammo yo'q: pastdagi «" + contactButton +
		"» tugmasini bosing — kirish kodini yuboramiz 👇"
	msgCodeLimit = "Bu raqamga juda ko'p kod so'raldi. Bir soatdan keyin qayta urinib ko'ring."
)

// botTexts — botni birinchi marta ochganda bo'sh chatda «START» tugmasi ustida ko'rinadigan matn. Havoladan kelganlarning
// ko'pi shu yerda to'xtab qolardi (START bosilmaydi): matn aynan nima qilishni aytadi.
var botTexts = []BotTexts{
	{
		Lang: "",
		Description: "Ustame — uy ta'miri uchun ishonchli ustalar va qurilish materiallari.\n\n" +
			"👇 Kirish uchun pastdagi «START» (yoki «Boshlash», «Запустить») tugmasini bosing, " +
			"keyin «" + contactButton + "» tugmasini bosing.",
		Short: "Ustame'ga kirish va bildirishnomalar. Ustalar va e'lonlar: ustame.com",
	},
	{
		Lang: "ru",
		Description: "Ustame — надёжные мастера для ремонта и стройматериалы.\n\n" +
			"👇 Чтобы войти, нажмите «Запустить» (START) внизу, затем кнопку «" + contactButton + "» (отправить номер).",
		Short: "Вход в Ustame и уведомления. Мастера и заказы: ustame.com",
	},
}

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
	if w.IdlePoll == 0 {
		w.IdlePoll = 6 * time.Hour
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
			for _, t := range botTexts {
				if err := w.TG.EnsureTexts(ctx, t); err != nil {
					log.Printf("telegram: bot tavsifi (%q) o'rnatilmadi: %v", t.Lang, err)
				}
			}
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
			w.send(ctx, chatID, w.reply(chatID, reply), markup)
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
		code := strings.TrimPrefix(arg, loginPrefix)
		if c, cyr := strings.CutSuffix(code, loginCyrSuffix); cyr {
			code = c
			w.loginLang.Store(chatID, "uzc")
		} else {
			w.loginLang.Delete(chatID)
		}
		if c, app := strings.CutSuffix(code, loginAppSuffix); app {
			code = c
			w.loginApp.Store(chatID, true)
		} else {
			w.loginApp.Delete(chatID)
		}
		ok, err := w.Store.BeginLogin(ctx, code, chatID)
		switch {
		case err != nil:
			log.Printf("telegram: kirishni boshlashda xato: %v", err)
			return
		case ok:
			reply, markup = w.loginReply(ctx, chatID)
		default:
			reply, markup = w.expiredReply(ctx, chatID)
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
	case m.Chat.Type == "private" && w.codesEnabled():
		// Havolasiz /start (botni qidiruvdan yoki QR'dan ochgan) yoki oddiy matn (ko'pincha raqamni qo'lda yozadi):
		// tanish chat'ga darhol kod, aks holda raqamni tugma orqali yuborishni so'raymiz
		w.loginLang.Delete(chatID)
		w.loginApp.Delete(chatID)
		if phone := w.knownPhone(ctx, chatID); phone != "" {
			reply, markup = w.codeReply(ctx, chatID, phone)
		} else {
			reply, markup = msgHello, askContactKeyboard
		}
	default:
		reply = msgHelloNoCode
	}
	w.send(ctx, chatID, w.reply(chatID, reply), markup)
}

func (w *Worker) codesEnabled() bool { return len(w.OTPSecret) > 0 }

func (w *Worker) knownPhone(ctx context.Context, chatID int64) string {
	phone, err := w.Store.KnownLoginPhone(ctx, chatID)
	if err != nil {
		log.Printf("telegram: tanish chat'ni tekshirishda xato: %v", err)
	}
	return phone
}

// issueCode — 6 xonali bir martalik kirish kodi (otp_codes). "" — berilmadi (o'chiq, limit yoki xato);
// limited — shu raqamga juda ko'p kod so'ralgan.
func (w *Worker) issueCode(ctx context.Context, phone string) (code string, limited bool) {
	if !w.codesEnabled() {
		return "", false
	}
	n, err := rand.Int(rand.Reader, big.NewInt(900000))
	if err != nil {
		log.Printf("telegram: kod yaratilmadi: %v", err)
		return "", false
	}
	code = fmt.Sprint(100000 + n.Int64())
	ok, err := w.Store.IssueLoginCode(ctx, phone, auth.HashCode(w.OTPSecret, phone, code))
	switch {
	case err != nil:
		log.Printf("telegram: kirish kodi saqlanmadi: %v", err)
		return "", false
	case !ok:
		return "", true
	}
	return code, false
}

// codeReply — kirish kodi xabari (saytdan kelganga — bir bosishda kirish tugmasi bilan) yoki limit/xato matni
func (w *Worker) codeReply(ctx context.Context, chatID int64, phone string) (string, any) {
	code, limited := w.issueCode(ctx, phone)
	switch {
	case code != "" && w.fromApp(chatID):
		return fmt.Sprintf(msgLoginCode, code), removeKeyboard
	case code != "":
		return fmt.Sprintf(msgLoginCodeLink, code), w.siteButton(chatID, btnLogin, phone, code)
	case limited:
		return msgCodeLimit, removeKeyboard
	}
	return msgLoginNoSession, removeKeyboard
}

func (w *Worker) fromApp(chatID int64) bool {
	_, ok := w.loginApp.Load(chatID)
	return ok
}

// siteButton — saytni ochib bot bergan kod bilan darhol kiritadigan tugma. Tugma ko'pincha Telegram ichidagi
// brauzerda ochiladi (kirish boshlangan oynada emas), shuning uchun kod havolaning o'zida: # dan keyingi qism
// serverga va jurnallarga bormaydi, sahifa uni o'qigach manzildan o'chiradi (ilova: src/app/(auth)/tg-login.tsx).
func (w *Worker) siteButton(chatID int64, title, phone, code string) any {
	site := w.SiteURL
	if site == "" {
		site = "https://ustame.com"
	}
	return map[string]any{"inline_keyboard": [][]map[string]any{{{
		"text": w.reply(chatID, title),
		"url":  site + "/tg-login#" + phone + "." + code,
	}}}}
}

// expiredReply — /start login_<kod> eskirgan yoki ishlatilgan. Kod berish yoqilgan bo'lsa odam havolani qayta
// ochishi shart emas: tanish chat'ga darhol kod, notanish chat'dan raqam so'raladi (keyin kod beriladi).
func (w *Worker) expiredReply(ctx context.Context, chatID int64) (string, any) {
	if !w.codesEnabled() {
		return msgLoginBadCode, nil
	}
	if phone := w.knownPhone(ctx, chatID); phone != "" {
		return w.codeReply(ctx, chatID, phone)
	}
	return msgLoginExpiredAsk, askContactKeyboard
}

// loginReply — /start login_<kod> dan keyin: chat avval shu foydalanuvchi sifatida tasdiqlangan bo'lsa,
// kirish darhol tasdiqlanadi (bir bosish); aks holda raqamni yuborish so'raladi.
func (w *Worker) loginReply(ctx context.Context, chatID int64) (string, any) {
	phone, err := w.Store.KnownLoginPhone(ctx, chatID)
	if err != nil {
		log.Printf("telegram: tanish chat'ni tekshirishda xato: %v", err)
	}
	if phone != "" {
		ok, err := w.Store.CompleteLogin(ctx, chatID, phone)
		if err != nil {
			log.Printf("telegram: kirishni tasdiqlashda xato: %v", err)
		}
		if ok {
			code, _ := w.issueCode(ctx, phone)
			switch {
			case code != "" && w.fromApp(chatID):
				return fmt.Sprintf(msgLoginKnownCode, code), removeKeyboard
			case code != "":
				return fmt.Sprintf(msgLoginKnownLink, code), w.siteButton(chatID, btnBack, phone, code)
			}
			return msgLoginKnown, removeKeyboard
		}
	}
	return msgLoginAsk, askContactKeyboard
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
		// Kutilayotgan kirish yo'q (havola eskirgan, botni o'zi topib ochgan va h.k.) — kirish kodini beramiz
		return w.codeReply(ctx, m.Chat.ID, phone)
	}
	// Tasdiqlandi: kutayotgan oyna o'zi kiradi. Zaxira kod ham — u oyna yopilib qolgan bo'lsa ham kiradi
	code, _ := w.issueCode(ctx, phone)
	switch {
	case code != "" && w.fromApp(m.Chat.ID):
		return fmt.Sprintf(msgLoginDoneCode, code), removeKeyboard
	case code != "":
		// Inline tugma bilan klaviatura yopilmaydi, lekin raqam tugmasi bir martalik — bosilgach o'zi yashirinadi
		return fmt.Sprintf(msgLoginDoneLink, code), w.siteButton(m.Chat.ID, btnBack, phone, code)
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

const deliverBatch = 20

func (w *Worker) deliverLoop(ctx context.Context) {
	for ctx.Err() == nil {
		wait, full := w.deliverOnce(ctx)
		switch {
		case wait > 0: // xato yoki 429 — shu muddatdan keyin qayta urinamiz
			if !sleep(ctx, wait) {
				return
			}
		case full: // navbatda yana xabar bor
		default:
			if !w.waitForWork(ctx) {
				return
			}
		}
	}
}

// waitForWork — API signalini yoki zaxira tekshiruv vaqtini kutadi; ctx bekor bo'lsa false.
func (w *Worker) waitForWork(ctx context.Context) bool {
	t := time.NewTimer(w.IdlePoll)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-w.Wake:
	case <-t.C:
	}
	return true
}

// deliverOnce — bir partiya xabarni yuboradi. wait — keyingi urinishgacha kutish (xatoda),
// full — partiya to'la edi, navbatda yana bo'lishi mumkin.
func (w *Worker) deliverOnce(ctx context.Context) (wait time.Duration, full bool) {
	list, err := w.Store.ClaimNotifications(ctx, deliverBatch)
	if err != nil {
		log.Printf("telegram: navbat o'qilmadi: %v", err)
		return w.RetryDelay, false
	}
	full = len(list) == deliverBatch
	for i, n := range list {
		if n.ChatID == nil {
			continue // botga ulanmagan foydalanuvchi — xabar shunchaki "yuborilgan" qoladi
		}
		err := w.TG.SendMessage(ctx, *n.ChatID, cyrillic.For(n.Lang, n.Text))
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
			return time.Duration(max(apiErr.RetryAfter, 1)) * time.Second, false
		case time.Since(n.CreatedAt) > w.MaxMessageAge:
			log.Printf("telegram: %d-xabar eskirdi, tashlab yuborildi: %v", n.ID, err)
		default:
			log.Printf("telegram: %d-xabar yuborilmadi, keyinroq qayta urinamiz: %v", n.ID, err)
			w.release(ctx, n.ID)
			wait = w.RetryDelay
		}
	}
	return wait, full
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
