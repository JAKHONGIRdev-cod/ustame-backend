package telegram

// «Usta chaqirish» — mijoz botning o'zida e'lon beradi (2026-11-27). Kasb va tuman tugmalar bilan (xato bo'lmasin),
// muammo ovoz yoki matn bilan (ovoz STT orqali matnga aylanadi), manzil — joylashuv tugmasi yoki matn, keyin vaqt.
// Mijoz tayyor e'lonni ko'rib tasdiqlaydi; raqami noma'lum bo'lsa oxirida «Raqamni yuborish» (kirishdagi kabi).
// Operator kerak emas: e'lon post_job orqali chiqadi va ustalarga odatdagidek xabar boradi.
//
// Kirish nuqtalari: t.me/<bot>?start=order[_<manba>[__<kampaniya>]] (reklama havolasi), /usta buyrug'i (menyu),
// «Usta chaqirish» tugmasi. Holat (TELEGRAM_ORDERS): off — o'chiq (standart), test — faqat ORDER_TEST_PHONES
// raqamlari uchun, on — hamma uchun. Sinov raqamlarining e'loni hech qachon saqlanmaydi va ustalarga bormaydi
// (tranzaksiya oxirida bekor qilinadi) — bot faqat kimga xabar ketishini aytadi.
// Qoralama xotirada turadi (oqim 1–3 daqiqa): server qayta ishga tushsa, boshlangan qoralama yo'qoladi.

import (
	"context"
	"errors"
	"fmt"
	"log"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	stepCategory       = "category"
	stepDistrict       = "district" // Toshkent shahri tumanlari + «Boshqa viloyat»
	stepRegion         = "region"
	stepRegionDistrict = "region_district"
	stepProblem        = "problem"
	stepAddress        = "address"
	stepUrgency        = "urgency"
	stepConfirm        = "confirm"
	stepPhone          = "phone"

	orderPrefix  = "order" // /start order, /start order_<manba>, /start order_<manba>__<kampaniya>
	orderCommand = "/usta"
	orderTTL     = 2 * time.Hour
	maxVoiceSec  = 120
	sttTimeout   = 40 * time.Second
)

// OrderMode — «Usta chaqirish» holati (TELEGRAM_ORDERS)
type OrderMode int

const (
	OrdersOff  OrderMode = iota // o'chiq (standart)
	OrdersTest                  // faqat sinov raqamlari (ORDER_TEST_PHONES) uchun; ularning e'loni saqlanmaydi
	OrdersOn                    // hamma uchun; sinov raqamlari baribir sinov rejimida
)

// ParseOrderMode — "on" | "test" | boshqa hamma narsa (bo'sh ham) — o'chiq
func ParseOrderMode(s string) OrderMode {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "on":
		return OrdersOn
	case "test":
		return OrdersTest
	}
	return OrdersOff
}

// Attribution — reklama manbasi: t.me/<bot>?start=order_<manba>__<kampaniya>. Telegram start parametrida faqat
// A-Z, a-z, 0-9, _ va - bo'ladi (64 belgigacha); SQL _clean_source kichik harfga o'tkazib tozalaydi.
type Attribution struct {
	Source   string // bo'sh — "telegram_bot"
	Campaign string
}

// parseOrderStart — /start argumenti buyurtma havolasimi; bo'lsa manba va kampaniya
func parseOrderStart(arg string) (Attribution, bool) {
	var rest string
	switch {
	case arg == orderPrefix:
	case strings.HasPrefix(arg, orderPrefix+"_"):
		rest = arg[len(orderPrefix)+1:]
	default:
		return Attribution{}, false
	}
	src, campaign, _ := strings.Cut(rest, "__")
	return Attribution{Source: src, Campaign: campaign}, true
}

// Tugmalar
const (
	btnOrder       = "🛠 Usta chaqirish"
	btnCancel      = "❌ Bekor qilish"
	btnPrev        = "⬅️ Orqaga"
	btnOtherRegion = "🗺 Boshqa viloyat"
	btnLocation    = "📍 Joylashuvni yuborish"
	btnPublish     = "✅ E'lon qilish"
	btnEditProblem = "✏️ Muammoni o'zgartirish"
	btnOffers      = "👀 Takliflarni ko'rish"
)

// orderCategories — tugma matni → bazadagi kasb qiymati (ilova: src/lib/options.ts CATEGORIES bilan bir xil)
var orderCategories = []struct{ Label, Value string }{
	{"🔧 Santexnik", "Santexnik"},
	{"⚡ Elektrik", "Elektrik"},
	{"❄️ Konditsioner ustasi", "Konditsioner ustasi"},
	{"🧊 Muzlatgich ustasi", "Muzlatgich ustasi"},
	{"🧱 Quruvchi/ta'mirchi", "Quruvchi/ta'mirchi"},
	{"🎨 Bo'yoqchi", "Bo'yoqchi"},
	{"🪑 Mebel ustasi", "Mebel ustasi"},
	{"🪚 Duradgor", "Duradgor"},
	{"🔥 Payvandchi", "Payvandchi"},
	{"🛠 Boshqa", "Boshqa"},
}

// orderUrgencies — «Shoshilinch» (urgent) ataylab yo'q: u faqat «hozir bo'shman» deb belgilagan ustalarga boradi
// (notify_urgent_job), qolganlar xabar olmaydi. Eng tezi — «Bugun».
var orderUrgencies = []struct{ Label, Value string }{
	{"📅 Bugun", "today"},
	{"🗓 Shu hafta ichida", "this_week"},
	{"🕊 Shoshilmayman", "flexible"},
}

const (
	msgOrderStart = "🛠 Usta chaqiramiz! 1 daqiqada e'lon beramiz — mos ustalar o'zlari narx taklif qiladi.\n\n" +
		"Qanday usta kerak? 👇"
	msgOrderDistrict       = "📍 Qaysi tumanda?"
	msgOrderRegion         = "Qaysi viloyatda?"
	msgOrderRegionDistrict = "Qaysi tumanda?"
	orderProblemExample    = "Masalan: «Hammomdagi trubadan suv oqyapti». Rasm bo'lsa, uni ham yuboring — usta narxni " +
		"aniqroq aytadi."
	// msgOrderProblemVoice — ovoz yoqilgan: ovoz tashqi xizmatga (%s — nomi) yuborilishi OLDINDAN aytiladi
	msgOrderProblemVoice = "📝 Muammoni ayting: 🎤 ovozli xabar yuboring yoki yozing.\n\n" + orderProblemExample +
		"\n\n🔒 Ovozli xabar matnga aylantirish uchun %s xizmatiga yuboriladi, Ustame ovozning o'zini saqlamaydi. " +
		"Xohlamasangiz — yozib yuboring."
	msgOrderProblemText = "📝 Muammoni yozib yuboring.\n\n" + orderProblemExample
	msgOrderPhotoOK     = "📷 Rasm qabul qilindi. Endi muammoni qisqacha yozing."
	msgOrderPhotoOKV    = "📷 Rasm qabul qilindi. Endi muammoni 🎤 ovoz bilan ayting yoki yozing."
	msgOrderListening   = "🎧 Eshityapman..."
	msgOrderHeard       = "Tushundim: «%s»"
	msgOrderVoiceFail   = "Ovozli xabarni tushunolmadim 😕 Iltimos, muammoni qisqacha yozib yuboring."
	msgOrderVoiceOff    = "Hozircha ovozli xabarni o'qiy olmayman 🙏 Muammoni qisqacha yozib yuboring."
	msgOrderVoiceLong   = "Ovozli xabar juda uzun. 2 daqiqagacha qisqaroq ayting yoki yozing."
	msgOrderTooShort    = "Biroz batafsilroq ayting: nima buzilgan yoki nima qilish kerak?"
	msgOrderAddress     = "🏠 Manzil: pastdagi «" + btnLocation + "» tugmasini bosing yoki manzilni yozing " +
		"(mahalla, ko'cha, uy).\n\nManzil faqat siz tanlagan ustaga ko'rinadi."
	msgOrderAddressBad  = "Manzilni yozing (masalan: «Qatortol ko'chasi, 12-uy») yoki «" + btnLocation + "» tugmasini bosing."
	msgOrderLocationBad = "Bu joylashuv O'zbekistondan tashqarida ko'rinyapti. Manzilni yozib yuboring."
	msgOrderUrgency     = "⏰ Usta qachon kerak?"
	msgOrderConfirm     = "Tekshirib chiqing:\n\n🛠 %s\n📍 %s\n📝 %s\n🏠 %s\n⏰ %s%s\n\nHammasi to'g'rimi?"
	msgOrderPhoneAsk    = "Oxirgi qadam: e'lon sizning nomingizdan chiqishi va ustalar takliflari shu yerga kelishi " +
		"uchun raqamingiz kerak.\n\nPastdagi «" + contactButton + "» tugmasini bosing, Telegram so'raganda «OK» ni bosing 👇"
	msgOrderPosted = "✅ E'loningiz joylandi!\n\nMos ustalarga xabar yuborildi. Ular narx taklif qilganda shu yerga " +
		"xabar keladi."
	msgOrderDuplicate = "✅ Bu e'lon allaqachon joylangan — ikkinchi marta yuborilmadi."
	msgOrderDryRun    = "🧪 Sinov rejimi: e'lon to'liq tekshirildi, lekin saqlanmadi va hech kimga yuborilmadi.\n\n" +
		"Haqiqiy e'londa xabar olardi: ustalar — %d, adminlar — %d."
	msgOrderOpen     = "Takliflarni ko'rish va ustani tanlash uchun pastdagi tugmani bosing 👇"
	msgOrderOpenCode = msgOrderOpen + "\n\nKirish kodi (kerak bo'lsa): %s\n\n" +
		"Kod 10 daqiqa amal qiladi. Keyinroq kirish uchun botga /start yozing — yangi tugma keladi."
	msgOrderCancelled = "Bekor qilindi. Usta kerak bo'lsa — " + orderCommand
	msgOrderBlocked   = "Hisobingiz bloklangan. Savollar bo'lsa: @Ustame_uz"
	msgOrderLimit     = "Bugun ko'p e'lon berdingiz. Ertaga qayta urinib ko'ring yoki @Ustame_uz ga yozing."
	msgOrderNoContact = "E'londa telefon raqam yoki havola bo'lmasligi kerak — ustalar siz bilan Ustame orqali " +
		"bog'lanadi. Muammoni raqamsiz qayta ayting."
	msgOrderFailed = "Kechirasiz, e'lonni joylab bo'lmadi. Birozdan keyin «" + btnPublish + "» ni qayta bosing " +
		"yoki @Ustame_uz ga yozing."
	msgOrderUseButtons = "Pastdagi tugmalardan birini tanlang 👇"
	msgOrderStale      = "Bu e'lon yakunlangan yoki eskirgan. Yangi e'lon berish uchun: " + orderCommand

	// noAddressText — manzil yozilmay, faqat joylashuv yuborilgan (post_job manzil matnini talab qiladi)
	noAddressText = "📍 Joylashuv xaritada belgilangan"
)

// OrderDraft — bot orqali yig'ilayotgan e'lon
type OrderDraft struct {
	Step        string
	Attribution Attribution // reklama manbasi (/start order_<manba>__<kampaniya>)
	Category    string
	Region      string // hudud kaliti (Toshkent shahri yoki «Boshqa viloyat»dan tanlangani)
	District    string
	Description string
	Address     string
	Location    *Location
	Urgency     string
	PhotoID     string
	UpdatedAt   time.Time
}

// Title — e'lon sarlavhasi (5–80 belgi): tavsifning birinchi gapi, uzun bo'lsa so'z chegarasida qisqartiriladi.
func (o *OrderDraft) Title() string {
	s := strings.TrimSpace(o.Description)
	if i := strings.IndexAny(s, ".!?\n"); i > 0 {
		s = strings.TrimSpace(s[:i])
	}
	if utf8.RuneCountInString(s) > 60 {
		r := []rune(s)[:60]
		cut := string(r)
		if i := strings.LastIndex(cut, " "); i > 20 {
			cut = cut[:i]
		}
		s = strings.TrimRight(cut, " ,;:-") + "…"
	}
	if utf8.RuneCountInString(s) < 5 {
		return o.Category + " kerak"
	}
	r := []rune(s)
	r[0] = unicode.ToUpper(r[0])
	return string(r)
}

// AddressText — post_job uchun manzil matni
func (o *OrderDraft) AddressText() string {
	if o.Address != "" {
		return o.Address
	}
	return noAddressText
}

func (o *OrderDraft) urgencyLabel() string {
	for _, u := range orderUrgencies {
		if u.Value == o.Urgency {
			return u.Label
		}
	}
	return o.Urgency
}

// orders — chat → qoralama (handleUpdate bitta goroutine'da ishlaydi, mutex — ehtiyot uchun)
type orders struct {
	mu sync.Mutex
	m  map[int64]*OrderDraft
}

func (ds *orders) get(chatID int64, now time.Time) *OrderDraft {
	ds.mu.Lock()
	defer ds.mu.Unlock()
	d := ds.m[chatID]
	if d != nil && now.Sub(d.UpdatedAt) > orderTTL {
		delete(ds.m, chatID)
		return nil
	}
	return d
}

func (ds *orders) put(chatID int64, d *OrderDraft) {
	ds.mu.Lock()
	defer ds.mu.Unlock()
	if ds.m == nil {
		ds.m = map[int64]*OrderDraft{}
	}
	ds.m[chatID] = d
}

func (ds *orders) drop(chatID int64) {
	ds.mu.Lock()
	defer ds.mu.Unlock()
	delete(ds.m, chatID)
}

// keyboard — oddiy (reply) klaviatura: bosilgan tugma matni xabar bo'lib keladi
func keyboard(rows [][]string, placeholder string) map[string]any {
	kb := make([][]map[string]any, 0, len(rows))
	for _, row := range rows {
		r := make([]map[string]any, 0, len(row))
		for _, t := range row {
			r = append(r, map[string]any{"text": t})
		}
		kb = append(kb, r)
	}
	m := map[string]any{"keyboard": kb, "resize_keyboard": true, "is_persistent": true}
	if placeholder != "" {
		m["input_field_placeholder"] = placeholder
	}
	return m
}

// chunk — tugmalarni qatorlarga bo'ladi
func chunk(items []string, n int) [][]string {
	var rows [][]string
	for len(items) > n {
		rows = append(rows, items[:n])
		items = items[n:]
	}
	if len(items) > 0 {
		rows = append(rows, items)
	}
	return rows
}

func categoryKeyboard() map[string]any {
	labels := make([]string, len(orderCategories))
	for i, c := range orderCategories {
		labels[i] = c.Label
	}
	return keyboard(append(chunk(labels, 2), []string{btnCancel}), "Kasbni tanlang")
}

func districtKeyboard() map[string]any {
	rows := chunk(regions[0].Districts, 3) // Toshkent shahri
	return keyboard(append(rows, []string{btnOtherRegion}, []string{btnCancel}), "Tumanni tanlang")
}

func regionKeyboard() map[string]any {
	names := make([]string, 0, len(regions)-1)
	for _, r := range regions[1:] {
		names = append(names, r.Name)
	}
	return keyboard(append(chunk(names, 2), []string{btnPrev}), "Viloyatni tanlang")
}

func regionDistrictKeyboard(r *Region) map[string]any {
	return keyboard(append(chunk(r.Districts, 3), []string{btnPrev}), "Tumanni tanlang")
}

func addressKeyboard() map[string]any {
	return map[string]any{
		"keyboard": [][]map[string]any{
			{{"text": btnLocation, "request_location": true}},
			{{"text": btnCancel}},
		},
		"resize_keyboard":         true,
		"is_persistent":           true,
		"input_field_placeholder": "Manzilni yozing yoki joylashuvni yuboring",
	}
}

func urgencyKeyboard() map[string]any {
	labels := make([]string, len(orderUrgencies))
	for i, u := range orderUrgencies {
		labels[i] = u.Label
	}
	return keyboard([][]string{labels[:1], labels[1:], {btnCancel}}, "")
}

func confirmKeyboard() map[string]any {
	return keyboard([][]string{{btnPublish}, {btnEditProblem, btnCancel}}, "")
}

var orderContactKeyboard = map[string]any{
	"keyboard": [][]map[string]any{
		{{"text": contactButton, "request_contact": true}},
		{{"text": btnCancel}},
	},
	"resize_keyboard":         true,
	"is_persistent":           true,
	"input_field_placeholder": "👇 «" + contactButton + "» tugmasini bosing",
}

func findRegion(key string) *Region {
	for i := range regions {
		if regions[i].Key == key {
			return &regions[i]
		}
	}
	return nil
}

// ordersEnabled — «Usta chaqirish» hech bo'lmasa sinov raqamlari uchun yoqilgan
func (w *Worker) ordersEnabled() bool { return w.Orders != nil && w.OrderMode != OrdersOff }

// ordersPublic — hamma uchun yoqilgan: salomlashuvda tugma, bot menyusi va tavsifi
func (w *Worker) ordersPublic() bool { return w.Orders != nil && w.OrderMode == OrdersOn }

func (w *Worker) isTestPhone(phone string) bool { return phone != "" && w.OrderTestPhones[phone] }

// orderAllowed — shu chat oqimni boshlay oladimi; test — chat sinov raqamiga tegishli (e'lon saqlanmaydi,
// manba yozilmaydi). Sinov holatida faqat Telegram orqali tasdiqlangan sinov raqamlari kiradi.
func (w *Worker) orderAllowed(ctx context.Context, chatID int64) (allowed, test bool) {
	if !w.ordersEnabled() {
		return false, false
	}
	test = w.isTestPhone(w.knownPhone(ctx, chatID))
	if w.OrderMode == OrdersTest {
		return test, test
	}
	return true, test
}

func (w *Worker) voiceEnabled() bool { return w.STT != nil }

// problemText — muammo so'rovi; ovoz yoqilgan bo'lsa, ovoz qaysi xizmatga yuborilishi oldindan aytiladi
func (w *Worker) problemText() string {
	if !w.voiceEnabled() {
		return msgOrderProblemText
	}
	return fmt.Sprintf(msgOrderProblemVoice, cmpOr(w.STTName, "OpenAI"))
}

func (w *Worker) problemKeyboard() map[string]any {
	if w.voiceEnabled() {
		return keyboard([][]string{{btnCancel}}, "Yozing yoki 🎤 ovoz yuboring")
	}
	return keyboard([][]string{{btnCancel}}, "Muammoni yozing")
}

// handleOrder — xabar «Usta chaqirish» oqimiga tegishli bo'lsa ishlaydi va true qaytaradi; aks holda xabar
// odatdagi (kirish, bildirishnomalar) yo'ldan boradi.
func (w *Worker) handleOrder(ctx context.Context, m *Message) bool {
	if !w.ordersEnabled() || m.Chat.Type != "private" {
		return false
	}
	chatID := m.Chat.ID
	text := strings.TrimSpace(m.Text)
	cmd, arg, _ := strings.Cut(text, " ")
	cmd, _, _ = strings.Cut(cmd, "@")
	arg = strings.TrimSpace(arg)

	if src, ok := parseOrderStart(arg); ok && cmd == "/start" {
		allowed, test := w.orderAllowed(ctx, chatID)
		if !allowed {
			// Oqim bu chat uchun yopiq (sinov holati): havola oddiy /start kabi ishlaydi (kirish), «kod noto'g'ri» emas
			m.Text = "/start"
			return false
		}
		w.startOrder(ctx, chatID, src, !test)
		return true
	}
	if cmd == orderCommand || text == btnOrder {
		if allowed, _ := w.orderAllowed(ctx, chatID); !allowed {
			return false
		}
		w.startOrder(ctx, chatID, Attribution{}, false) // menyu yoki tugma — reklama tashrifi emas
		return true
	}

	d := w.drafts.get(chatID, time.Now())
	if d == nil {
		if isOrderButton(text) {
			// Eski tugma: e'lon allaqachon yuborilgan, bekor qilingan yoki server qayta ishga tushgan
			w.send(ctx, chatID, msgOrderStale, removeKeyboard)
			return true
		}
		return false
	}
	if strings.HasPrefix(text, "/") {
		// Boshqa buyruq (/start login_..., /stop): qoralama tashlanadi, buyruq odatdagidek ishlaydi
		w.drafts.drop(chatID)
		return false
	}
	if m.Contact != nil && d.Step != stepPhone {
		return false // kirish oqimidagi kontakt
	}
	if text == btnCancel {
		w.drafts.drop(chatID)
		w.send(ctx, chatID, msgOrderCancelled, removeKeyboard)
		return true
	}
	d.UpdatedAt = time.Now()

	switch d.Step {
	case stepCategory:
		for _, c := range orderCategories {
			if text == c.Label || text == c.Value {
				d.Category = c.Value
				d.Step = stepDistrict
				w.send(ctx, chatID, msgOrderDistrict, districtKeyboard())
				return true
			}
		}
		w.send(ctx, chatID, msgOrderUseButtons, categoryKeyboard())

	case stepDistrict:
		switch {
		case text == btnOtherRegion:
			d.Step = stepRegion
			w.send(ctx, chatID, msgOrderRegion, regionKeyboard())
		case slices.Contains(regions[0].Districts, text):
			d.District, d.Region = text, regions[0].Key
			w.askProblem(ctx, chatID, d)
		default:
			w.send(ctx, chatID, msgOrderUseButtons, districtKeyboard())
		}

	case stepRegion:
		if text == btnPrev {
			d.Step = stepDistrict
			w.send(ctx, chatID, msgOrderDistrict, districtKeyboard())
			return true
		}
		for i := range regions[1:] {
			r := &regions[i+1]
			if text == r.Name {
				d.Region = r.Key
				d.Step = stepRegionDistrict
				w.send(ctx, chatID, msgOrderRegionDistrict, regionDistrictKeyboard(r))
				return true
			}
		}
		w.send(ctx, chatID, msgOrderUseButtons, regionKeyboard())

	case stepRegionDistrict:
		r := findRegion(d.Region)
		switch {
		case text == btnPrev || r == nil:
			d.Step = stepRegion
			w.send(ctx, chatID, msgOrderRegion, regionKeyboard())
		case slices.Contains(r.Districts, text):
			d.District = text
			w.askProblem(ctx, chatID, d)
		default:
			w.send(ctx, chatID, msgOrderUseButtons, regionDistrictKeyboard(r))
		}

	case stepProblem:
		w.orderProblem(ctx, m, d)

	case stepAddress:
		switch {
		case m.Location != nil:
			loc := *m.Location
			if loc.Latitude < 37 || loc.Latitude > 46 || loc.Longitude < 55 || loc.Longitude > 74 {
				w.send(ctx, chatID, msgOrderLocationBad, addressKeyboard())
				return true
			}
			d.Location = &loc
		case utf8.RuneCountInString(text) >= 5 && utf8.RuneCountInString(text) <= 300 && text != btnLocation:
			d.Address = text
		default:
			w.send(ctx, chatID, msgOrderAddressBad, addressKeyboard())
			return true
		}
		d.Step = stepUrgency
		w.send(ctx, chatID, msgOrderUrgency, urgencyKeyboard())

	case stepUrgency:
		for _, u := range orderUrgencies {
			if text == u.Label {
				d.Urgency = u.Value
				w.askConfirm(ctx, chatID, d)
				return true
			}
		}
		w.send(ctx, chatID, msgOrderUseButtons, urgencyKeyboard())

	case stepConfirm:
		switch text {
		case btnPublish:
			phone := w.knownPhone(ctx, chatID)
			if phone == "" {
				d.Step = stepPhone
				w.send(ctx, chatID, msgOrderPhoneAsk, orderContactKeyboard)
				return true
			}
			w.publishOrder(ctx, m, d, phone)
		case btnEditProblem:
			w.askProblem(ctx, chatID, d)
		default:
			w.send(ctx, chatID, msgOrderUseButtons, confirmKeyboard())
		}

	case stepPhone:
		if m.Contact == nil {
			if looksLikePhone(text) {
				w.send(ctx, chatID, msgTypedPhone, orderContactKeyboard)
			} else {
				w.send(ctx, chatID, msgOrderPhoneAsk, orderContactKeyboard)
			}
			return true
		}
		if m.From == nil || m.Contact.UserID != m.From.ID {
			w.send(ctx, chatID, msgLoginNotOwn, orderContactKeyboard)
			return true
		}
		phone, ok := uzPhone(m.Contact.PhoneNumber)
		if !ok {
			w.drafts.drop(chatID)
			w.send(ctx, chatID, msgLoginNotUz, removeKeyboard)
			return true
		}
		w.publishOrder(ctx, m, d, phone)
	}
	return true
}

// startOrder — yangi qoralama. track — reklama havolasidan kelgan tashrif visit_sources ga yoziladi
// (menyu/tugma va sinov raqamlari yozilmaydi).
func (w *Worker) startOrder(ctx context.Context, chatID int64, src Attribution, track bool) {
	w.pendingAsk.Delete(chatID) // kirish eslatmasi oqim o'rtasida kelmasin
	w.drafts.put(chatID, &OrderDraft{Step: stepCategory, Attribution: src, UpdatedAt: time.Now()})
	if track {
		if err := w.Orders.TrackOrderVisit(ctx, src); err != nil {
			log.Printf("telegram: buyurtma manbasi yozilmadi: %v", err)
		}
	}
	w.send(ctx, chatID, msgOrderStart, categoryKeyboard())
}

func (w *Worker) askProblem(ctx context.Context, chatID int64, d *OrderDraft) {
	d.Step = stepProblem
	w.send(ctx, chatID, w.problemText(), w.problemKeyboard())
}

func (w *Worker) askConfirm(ctx context.Context, chatID int64, d *OrderDraft) {
	d.Step = stepConfirm
	photo := ""
	if d.PhotoID != "" {
		photo = "\n📷 Rasm bor"
	}
	place := d.District
	if r := findRegion(d.Region); r != nil {
		place = d.District + ", " + r.Name
	}
	w.send(ctx, chatID, fmt.Sprintf(msgOrderConfirm, d.Category, place, d.Description, d.AddressText(),
		d.urgencyLabel(), photo), confirmKeyboard())
}

// orderProblem — muammo: matn, ovozli xabar yoki rasm (izohi bo'lsa — izoh tavsif bo'ladi)
func (w *Worker) orderProblem(ctx context.Context, m *Message, d *OrderDraft) {
	chatID := m.Chat.ID
	text := strings.TrimSpace(m.Text)
	if len(m.Photo) > 0 {
		d.PhotoID = bestPhoto(m.Photo)
		text = strings.TrimSpace(m.Caption)
		if text == "" {
			reply := msgOrderPhotoOK
			if w.voiceEnabled() {
				reply = msgOrderPhotoOKV
			}
			w.send(ctx, chatID, reply, w.problemKeyboard())
			return
		}
	}
	if voice := cmpMedia(m.Voice, m.Audio); voice != nil {
		heard, reply := w.transcribe(ctx, chatID, voice)
		if heard == "" {
			w.send(ctx, chatID, reply, w.problemKeyboard())
			return
		}
		text = heard
		w.send(ctx, chatID, fmt.Sprintf(msgOrderHeard, truncate(heard, 300)), nil)
	}
	if utf8.RuneCountInString(text) < 10 {
		w.send(ctx, chatID, msgOrderTooShort, w.problemKeyboard())
		return
	}
	d.Description = truncate(text, 1990)
	if d.Address != "" || d.Location != nil {
		// «Muammoni o'zgartirish»dan qaytgan: manzil va vaqt allaqachon bor
		w.askConfirm(ctx, chatID, d)
		return
	}
	d.Step = stepAddress
	w.send(ctx, chatID, msgOrderAddress, addressKeyboard())
}

// transcribe — ovozni matnga aylantiradi. Bo'sh matn qaytsa — reply foydalanuvchiga aytiladigan sabab.
// Ovoz faqat shu yerda (muammo bosqichida, so'rovda ogohlantirilgandan keyin) tashqi xizmatga yuboriladi.
func (w *Worker) transcribe(ctx context.Context, chatID int64, v *Media) (text, reply string) {
	if !w.voiceEnabled() {
		return "", msgOrderVoiceOff
	}
	if v.Duration > maxVoiceSec {
		return "", msgOrderVoiceLong
	}
	w.send(ctx, chatID, msgOrderListening, nil)
	ctx, cancel := context.WithTimeout(ctx, sttTimeout)
	defer cancel()
	audio, err := w.TG.DownloadFile(ctx, v.FileID)
	if err != nil {
		log.Printf("telegram: ovoz yuklab olinmadi: %v", err)
		return "", msgOrderVoiceFail
	}
	text, err = w.STT.Transcribe(ctx, audio, "voice.ogg")
	if err != nil {
		log.Printf("telegram: ovoz matnga aylantirilmadi: %v", err)
		return "", msgOrderVoiceFail
	}
	if utf8.RuneCountInString(text) < 10 {
		return "", msgOrderVoiceFail
	}
	return text, ""
}

// publishOrder — mijozni bog'laydi va e'lonni joylaydi. Sinov raqami — hammasi tekshiriladi, lekin saqlanmaydi.
func (w *Worker) publishOrder(ctx context.Context, m *Message, d *OrderDraft, phone string) {
	chatID := m.Chat.ID
	dryRun := w.isTestPhone(phone)
	var err error
	if !dryRun {
		name := ""
		if m.From != nil {
			name = strings.TrimSpace(m.From.FirstName + " " + m.From.LastName)
		}
		err = w.Orders.EnsureClient(ctx, chatID, phone, name, d.Attribution)
	}
	var res OrderResult
	if err == nil {
		var photo []byte
		if d.PhotoID != "" {
			if photo, err = w.TG.DownloadFile(ctx, d.PhotoID); err != nil {
				log.Printf("telegram: e'lon rasmi yuklab olinmadi, rasmsiz joylanadi: %v", err)
				photo = nil
			}
		}
		res, err = w.Orders.PostOrder(ctx, phone, d, photo, dryRun)
	}
	var oe OrderError
	switch {
	case errors.Is(err, ErrBlocked), errors.As(err, &oe) && oe == "AUTH_REQUIRED":
		w.drafts.drop(chatID)
		w.send(ctx, chatID, msgOrderBlocked, removeKeyboard)
		return
	case errors.As(err, &oe) && oe == "ORDER_LIMIT":
		w.drafts.drop(chatID)
		w.send(ctx, chatID, msgOrderLimit, removeKeyboard)
		return
	case errors.As(err, &oe) && oe == "CONTACT_NOT_ALLOWED":
		d.Step = stepProblem
		w.send(ctx, chatID, msgOrderNoContact, w.problemKeyboard())
		return
	case err != nil:
		log.Printf("telegram: e'lon joylanmadi: %v", err)
		d.Step = stepConfirm
		w.send(ctx, chatID, msgOrderFailed, confirmKeyboard())
		return
	}

	w.drafts.drop(chatID)
	switch {
	case res.Duplicate:
		// Qayta bosish, javob yetib bormagan urinish yoki ikki nusxa: yangi e'lon yaratilmadi (PostOrder)
		log.Printf("telegram: takroriy e'lon yaratilmadi: %s", res.JobID)
		w.send(ctx, chatID, msgOrderDuplicate, removeKeyboard)
	case dryRun:
		log.Printf("telegram: sinov e'loni (saqlanmadi): %s, %s — ustalar %d, adminlar %d",
			d.Category, d.District, res.Providers, res.Admins)
		w.send(ctx, chatID, fmt.Sprintf(msgOrderDryRun, res.Providers, res.Admins), removeKeyboard)
		return
	default:
		log.Printf("telegram: bot orqali e'lon joylandi: %s (%s, %s) — ustalar %d, adminlar %d",
			res.JobID, d.Category, d.District, res.Providers, res.Admins)
		if w.OutboxNotify != nil {
			w.OutboxNotify() // ustalarga xabar (Telegram va push) darhol ketsin
		}
		w.send(ctx, chatID, msgOrderPosted, removeKeyboard)
	}
	if code, _ := w.issueCode(ctx, phone); code != "" {
		w.send(ctx, chatID, fmt.Sprintf(msgOrderOpenCode, code), w.siteButton(chatID, btnOffers, phone, code))
		return
	}
	site := cmpOr(w.SiteURL, "https://ustame.com")
	w.send(ctx, chatID, msgOrderOpen, map[string]any{"inline_keyboard": [][]map[string]any{{{
		"text": btnOffers, "url": site,
	}}}})
}

// bestPhoto — kattaroq, lekin 1600 px dan oshmaydigan o'lcham (Telegram o'lchamlarni kichigidan beradi)
func bestPhoto(sizes []PhotoSize) string {
	best := sizes[0].FileID
	for _, p := range sizes {
		if p.Width <= 1600 && p.Height <= 1600 {
			best = p.FileID
		}
	}
	return best
}

// isOrderButton — matn oqimdagi tugmalardan biri (qoralamasiz bosilsa — eskirgan tugma)
func isOrderButton(text string) bool {
	switch text {
	case btnCancel, btnPrev, btnOtherRegion, btnPublish, btnEditProblem:
		return true
	}
	for _, c := range orderCategories {
		if text == c.Label {
			return true
		}
	}
	for _, u := range orderUrgencies {
		if text == u.Label {
			return true
		}
	}
	return false
}

func cmpMedia(a, b *Media) *Media {
	if a != nil {
		return a
	}
	return b
}
