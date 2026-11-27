package telegram

import (
	"context"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// fakeOrders — OrderStore o'rnida: chaqiruvlarni yozib oladi
type fakeOrders struct {
	clients []string // "chat:raqam:ism:manba:kampaniya"
	posted  []OrderDraft
	phones  []string
	photos  [][]byte
	dryRuns []bool
	visits  []string // "manba/kampaniya"
	postErr error
	result  OrderResult // PostOrder natijasi (JobID bo'sh bo'lsa — standart id)
}

func (f *fakeOrders) EnsureClient(_ context.Context, chatID int64, phone, name string, src Attribution) error {
	f.clients = append(f.clients,
		strings.Join([]string{strconv.FormatInt(chatID, 10), phone, name, src.Source, src.Campaign}, ":"))
	return nil
}

func (f *fakeOrders) PostOrder(_ context.Context, phone string, o *OrderDraft, photo []byte, dryRun bool) (OrderResult, error) {
	if f.postErr != nil {
		return OrderResult{}, f.postErr
	}
	f.posted = append(f.posted, *o)
	f.phones = append(f.phones, phone)
	f.photos = append(f.photos, photo)
	f.dryRuns = append(f.dryRuns, dryRun)
	res := f.result
	if res.JobID == "" {
		res.JobID = "00000000-0000-0000-0000-000000000001"
	}
	return res, nil
}

func (f *fakeOrders) TrackOrderVisit(_ context.Context, src Attribution) error {
	f.visits = append(f.visits, src.Source+"/"+src.Campaign)
	return nil
}

func timeNow() time.Time { return time.Now() }

type fakeSTT struct {
	text  string
	calls int
}

func (f *fakeSTT) Transcribe(_ context.Context, audio []byte, _ string) (string, error) {
	f.calls++
	if string(audio) != "BIN" {
		return "", context.Canceled
	}
	return f.text, nil
}

// newOrderTest — «Usta chaqirish» hamma uchun yoqilgan bot (TELEGRAM_ORDERS=on), kirish kodlari bilan
func newOrderTest(t *testing.T) (*Worker, *fakeTG, *fakeStore, *fakeOrders) {
	w, tg, st := newCodeTest(t)
	ord := &fakeOrders{}
	w.Orders = ord
	w.OrderMode = OrdersOn
	w.OrderTestPhones = map[string]bool{}
	return w, tg, st, ord
}

// say — chatga matn yuboradi va botning oxirgi javobini qaytaradi
func say(t *testing.T, w *Worker, tg *fakeTG, u Update) (string, any) {
	t.Helper()
	before := tg.count()
	w.handleUpdate(context.Background(), u)
	if tg.count() == before {
		t.Fatalf("bot javob bermadi: %+v", u.Message)
	}
	return tg.sent[len(tg.sent)-1].Text, tg.markups[len(tg.markups)-1]
}

// buttons — klaviaturadagi barcha tugma matnlari
func buttons(markup any) []string {
	m, _ := markup.(map[string]any)
	var out []string
	for _, row := range asSlice(m["keyboard"]) {
		for _, b := range asSlice(row) {
			if bm, ok := b.(map[string]any); ok {
				out = append(out, bm["text"].(string))
			}
		}
	}
	return out
}

func asSlice(v any) []any {
	s, _ := v.([]any)
	return s
}

func has(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

func TestOrderFullFlowKnownChat(t *testing.T) {
	w, tg, st, ord := newOrderTest(t)
	notified := 0
	w.OutboxNotify = func() { notified++ }
	st.known[50] = "998901234567"

	text, kb := say(t, w, tg, privateMsg(50, "/start order_instagram__nov25"))
	if text != msgOrderStart || !has(buttons(kb), "🔧 Santexnik") {
		t.Fatalf("boshlanish: %q %v", text, buttons(kb))
	}
	text, kb = say(t, w, tg, privateMsg(50, "🔧 Santexnik"))
	if text != msgOrderDistrict || !has(buttons(kb), "Chilonzor") || !has(buttons(kb), btnOtherRegion) {
		t.Fatalf("tuman: %q %v", text, buttons(kb))
	}
	if text, _ = say(t, w, tg, privateMsg(50, "Chilonzor")); text != msgOrderProblemText {
		t.Fatalf("muammo: %q", text)
	}
	if text, _ = say(t, w, tg, privateMsg(50, "Hammomdagi trubadan suv oqyapti. Tezroq kerak")); text != msgOrderAddress {
		t.Fatalf("manzil: %q", text)
	}
	if text, _ = say(t, w, tg, privateMsg(50, "Qatortol ko'chasi, 12-uy")); text != msgOrderUrgency {
		t.Fatalf("vaqt: %q", text)
	}
	text, kb = say(t, w, tg, privateMsg(50, "📅 Bugun"))
	for _, part := range []string{"Santexnik", "Chilonzor, Toshkent shahri", "Hammomdagi trubadan", "Qatortol", "Bugun"} {
		if !strings.Contains(text, part) {
			t.Errorf("tasdiq matnida %q yo'q: %q", part, text)
		}
	}
	if !has(buttons(kb), btnPublish) {
		t.Fatalf("tasdiq tugmasi yo'q: %v", buttons(kb))
	}

	w.handleUpdate(context.Background(), privateMsg(50, btnPublish))
	if len(ord.posted) != 1 || ord.phones[0] != "998901234567" || ord.dryRuns[0] {
		t.Fatalf("e'lon joylanmadi: %+v %v %v", ord.posted, ord.phones, ord.dryRuns)
	}
	o := ord.posted[0]
	if o.Category != "Santexnik" || o.District != "Chilonzor" || o.Urgency != "today" ||
		o.Address != "Qatortol ko'chasi, 12-uy" || o.Title() != "Hammomdagi trubadan suv oqyapti" {
		t.Fatalf("e'lon maydonlari: %+v, sarlavha %q", o, o.Title())
	}
	// Manba: havoladagi manba va kampaniya mijozga (signup_source) beriladi; tashrif faqat boshida bir marta
	if len(ord.clients) != 1 || ord.clients[0] != "50:998901234567::instagram:nov25" {
		t.Fatalf("EnsureClient: %v", ord.clients)
	}
	if strings.Join(ord.visits, ",") != "instagram/nov25" {
		t.Fatalf("tashriflar: %v", ord.visits)
	}
	if notified != 1 {
		t.Fatalf("OutboxNotify chaqirilmadi")
	}
	// Oxirgi ikki xabar: «joylandi» (klaviatura yopiladi) va takliflarni ko'rish tugmasi (kirish kodi bilan)
	n := len(tg.sent)
	if tg.sent[n-2].Text != msgOrderPosted {
		t.Fatalf("joylandi xabari: %q", tg.sent[n-2].Text)
	}
	sentCode(t, w, st, tg.sent[n-1].Text, "998901234567")
	if title, url := siteButton(tg.markups[n-1]); title != btnOffers || !strings.Contains(url, "/tg-login#998901234567.") {
		t.Fatalf("takliflar tugmasi: %q %q", title, url)
	}
	if w.drafts.get(50, o.UpdatedAt) != nil {
		t.Fatal("qoralama o'chirilmadi")
	}
	// «E'lon qilish» qayta bosilsa — ikkinchi e'lon yo'q, kirish kodi ham emas
	if text, _ := say(t, w, tg, privateMsg(50, btnPublish)); text != msgOrderStale || len(ord.posted) != 1 {
		t.Fatalf("eski tugma: %q, e'lonlar %d", text, len(ord.posted))
	}
}

func TestOrderUnknownChatAsksContactAtEnd(t *testing.T) {
	w, tg, _, ord := newOrderTest(t)
	reachConfirm(t, w, tg, 60)

	text, kb := say(t, w, tg, privateMsg(60, btnPublish))
	if text != msgOrderPhoneAsk || !askedForContact(kb) {
		t.Fatalf("raqam so'ralmadi: %q", text)
	}
	if text, _ = say(t, w, tg, contactMsg(60, 999, "+998 90 111 22 33")); text != msgLoginNotOwn {
		t.Fatalf("begona kontakt: %q", text)
	}
	if text, _ = say(t, w, tg, privateMsg(60, "+998901112233")); text != msgTypedPhone {
		t.Fatalf("qo'lda yozilgan raqam: %q", text)
	}
	u := contactMsg(60, 60, "+998 90 111 22 33")
	u.Message.From.FirstName, u.Message.From.LastName = "Ali", "Valiyev"
	w.handleUpdate(context.Background(), u)
	if len(ord.posted) != 1 || ord.phones[0] != "998901112233" {
		t.Fatalf("e'lon joylanmadi: %v", ord.phones)
	}
	// /usta (menyu) — reklama tashrifi emas: manba bo'sh, tashrif yozilmaydi
	if ord.clients[0] != "60:998901112233:Ali Valiyev::" || len(ord.visits) != 0 {
		t.Fatalf("mijoz: %v, tashriflar: %v", ord.clients, ord.visits)
	}
}

// reachConfirm — /usta dan tasdiq bosqichigacha (matn bilan)
func reachConfirm(t *testing.T, w *Worker, tg *fakeTG, chat int64) {
	t.Helper()
	for _, s := range []string{orderCommand, "⚡ Elektrik", "Yunusobod", "Rozetkadan uchqun chiqyapti, almashtirish kerak",
		"Amir Temur ko'chasi 5", "🕊 Shoshilmayman"} {
		w.handleUpdate(context.Background(), privateMsg(chat, s))
	}
	if d := w.drafts.get(chat, timeNow()); d == nil || d.Step != stepConfirm {
		t.Fatalf("tasdiq bosqichiga yetmadi: %+v (oxirgi javob %q)", d, tg.sent[len(tg.sent)-1].Text)
	}
}

func TestOrderVoice(t *testing.T) {
	w, tg, _, _ := newOrderTest(t)
	for _, s := range []string{orderCommand, "🔧 Santexnik"} {
		w.handleUpdate(context.Background(), privateMsg(70, s))
	}
	// STT ulanmagan: so'rovda ovoz haqida gap yo'q, ovoz kelsa — yozib yuborish so'raladi
	text, kb := say(t, w, tg, privateMsg(70, "Sergeli"))
	if text != msgOrderProblemText || strings.Contains(text, "🎤") || strings.Contains(text, "OpenAI") {
		t.Fatalf("STT'siz so'rov: %q", text)
	}
	if kb.(map[string]any)["input_field_placeholder"] != "Muammoni yozing" {
		t.Fatalf("STT'siz klaviatura: %v", kb)
	}
	voice := privateMsg(70, "")
	voice.Message.Voice = &Media{FileID: "v1", Duration: 6}
	if text, _ := say(t, w, tg, voice); text != msgOrderVoiceOff {
		t.Fatalf("STT yo'q: %q", text)
	}

	// STT ulandi: muammo so'rovining o'zida ovoz qaysi xizmatga yuborilishi OLDINDAN aytiladi
	stt := &fakeSTT{text: "Oshxonada kran oqyapti, almashtirish kerak"}
	w.STT, w.STTName = stt, "OpenAI"
	w.handleUpdate(context.Background(), privateMsg(70, orderCommand))
	w.handleUpdate(context.Background(), privateMsg(70, "🔧 Santexnik"))
	text, _ = say(t, w, tg, privateMsg(70, "Sergeli"))
	if !strings.Contains(text, "🔒 Ovozli xabar matnga aylantirish uchun OpenAI xizmatiga yuboriladi") ||
		!strings.Contains(text, "Xohlamasangiz — yozib yuboring") {
		t.Fatalf("ovoz ogohlantiruvi yo'q: %q", text)
	}
	if stt.calls != 0 {
		t.Fatal("ovoz ogohlantirishdan oldin yuborildi")
	}
	before := tg.count()
	if text, _ := say(t, w, tg, voice); text != msgOrderAddress {
		t.Fatalf("ovozdan keyin manzil so'ralmadi: %q", text)
	}
	got := tg.sent[before:]
	if got[0].Text != msgOrderListening || !strings.Contains(got[1].Text, "Oshxonada kran oqyapti") {
		t.Fatalf("eshityapman/tushundim: %v", got)
	}
	if d := w.drafts.get(70, timeNow()); d.Description != stt.text {
		t.Fatalf("tavsif: %q", d.Description)
	}

	// Juda uzun ovoz STT'ga yuborilmaydi
	w.drafts.get(70, timeNow()).Step = stepProblem
	long := privateMsg(70, "")
	long.Message.Voice = &Media{FileID: "v2", Duration: 600}
	if text, _ := say(t, w, tg, long); text != msgOrderVoiceLong || stt.calls != 1 {
		t.Fatalf("uzun ovoz: %q, chaqiruvlar %d", text, stt.calls)
	}
	// Ovozdan juda qisqa matn chiqsa — qayta so'raladi
	stt.text = "ha"
	if text, _ := say(t, w, tg, voice); text != msgOrderVoiceFail {
		t.Fatalf("qisqa ovoz: %q", text)
	}
}

func TestOrderPhotoWithCaption(t *testing.T) {
	w, tg, st, ord := newOrderTest(t)
	st.known[75] = "998901230000"
	for _, s := range []string{orderCommand, "❄️ Konditsioner ustasi", "Mirobod"} {
		w.handleUpdate(context.Background(), privateMsg(75, s))
	}
	photo := privateMsg(75, "")
	photo.Message.Photo = []PhotoSize{{FileID: "p-small", Width: 90}, {FileID: "p-big", Width: 1280}, {FileID: "p-huge", Width: 2560}}
	if text, _ := say(t, w, tg, photo); text != msgOrderPhotoOK {
		t.Fatalf("izohsiz rasm: %q", text)
	}
	photo.Message.Caption = "Konditsioner sovutmayapti, tekshirish kerak"
	if text, _ := say(t, w, tg, photo); text != msgOrderAddress {
		t.Fatalf("izohli rasm: %q", text)
	}
	loc := privateMsg(75, "")
	loc.Message.Location = &Location{Latitude: 41.3, Longitude: 69.27}
	w.handleUpdate(context.Background(), loc)
	w.handleUpdate(context.Background(), privateMsg(75, "🗓 Shu hafta ichida"))
	text, _ := say(t, w, tg, privateMsg(75, btnPublish))
	if text == msgOrderFailed || len(ord.posted) != 1 {
		t.Fatalf("joylanmadi: %q", text)
	}
	o := ord.posted[0]
	if o.PhotoID != "p-big" || string(ord.photos[0]) != "BIN" || o.Location == nil || o.AddressText() != noAddressText {
		t.Fatalf("rasm/joylashuv: %+v, rasm %q", o, ord.photos[0])
	}
}

func TestOrderOtherRegion(t *testing.T) {
	w, tg, _, _ := newOrderTest(t)
	w.handleUpdate(context.Background(), privateMsg(80, orderCommand))
	w.handleUpdate(context.Background(), privateMsg(80, "🪑 Mebel ustasi"))
	text, kb := say(t, w, tg, privateMsg(80, btnOtherRegion))
	if text != msgOrderRegion || !has(buttons(kb), "Samarqand viloyati") || has(buttons(kb), "Toshkent shahri") {
		t.Fatalf("viloyatlar: %q %v", text, buttons(kb))
	}
	text, kb = say(t, w, tg, privateMsg(80, "Samarqand viloyati"))
	if text != msgOrderRegionDistrict || !has(buttons(kb), "Samarqand tumani") {
		t.Fatalf("tumanlar: %v", buttons(kb))
	}
	// Orqaga — viloyatlar ro'yxati
	if text, _ = say(t, w, tg, privateMsg(80, btnPrev)); text != msgOrderRegion {
		t.Fatalf("orqaga: %q", text)
	}
	w.handleUpdate(context.Background(), privateMsg(80, "Samarqand viloyati"))
	// Boshqa viloyatning tumani qabul qilinmaydi
	if text, _ = say(t, w, tg, privateMsg(80, "Chilonzor")); text != msgOrderUseButtons {
		t.Fatalf("begona tuman: %q", text)
	}
	if text, _ = say(t, w, tg, privateMsg(80, "Samarqand tumani")); text != msgOrderProblemText {
		t.Fatalf("muammo so'ralmadi: %q", text)
	}
	if d := w.drafts.get(80, timeNow()); d.District != "Samarqand tumani" || d.Region != "samarqand" {
		t.Fatalf("tuman: %+v", d)
	}
}

func TestOrderCancelAndOtherCommands(t *testing.T) {
	w, tg, st, _ := newOrderTest(t)
	w.handleUpdate(context.Background(), privateMsg(90, orderCommand))
	if text, kb := say(t, w, tg, privateMsg(90, btnCancel)); text != msgOrderCancelled || kb == nil {
		t.Fatalf("bekor: %q", text)
	}
	if w.drafts.get(90, timeNow()) != nil {
		t.Fatal("qoralama qoldi")
	}
	// Oqim o'rtasida /stop — qoralama tashlanadi, bildirishnomalar odatdagidek uziladi
	w.handleUpdate(context.Background(), privateMsg(91, orderCommand))
	w.handleUpdate(context.Background(), privateMsg(91, "/stop"))
	if w.drafts.get(91, timeNow()) != nil || len(st.unlinked) != 1 {
		t.Fatalf("/stop: qoralama %v, uzilgan %v", w.drafts.get(91, timeNow()), st.unlinked)
	}
	// Kasb tugmasidan boshqa matn — tugmalar qayta ko'rsatiladi
	w.handleUpdate(context.Background(), privateMsg(92, orderCommand))
	if text, kb := say(t, w, tg, privateMsg(92, "salom")); text != msgOrderUseButtons || !has(buttons(kb), "⚡ Elektrik") {
		t.Fatalf("noto'g'ri tugma: %q", text)
	}
}

func TestOrderLoginStillWorksOutsideFlow(t *testing.T) {
	w, tg, st, _ := newOrderTest(t)
	st.loginCodes["abc"] = true
	w.handleUpdate(context.Background(), privateMsg(100, "/start login_abc"))
	w.handleUpdate(context.Background(), contactMsg(100, 100, "+998901234567"))
	if st.verified[100] != "998901234567" {
		t.Fatalf("kirish ishlamadi: %v (javob %q)", st.verified, tg.sent[len(tg.sent)-1].Text)
	}
}

func TestPlainStartOffersOrder(t *testing.T) {
	w, tg, _, _ := newOrderTest(t)
	text, kb := say(t, w, tg, privateMsg(110, "/start"))
	if text != msgHelloOrder || !askedForContact(kb) || !has(buttons(kb), btnOrder) {
		t.Fatalf("salom: %q %v", text, buttons(kb))
	}
	if text, _ = say(t, w, tg, privateMsg(110, btnOrder)); text != msgOrderStart {
		t.Fatalf("usta chaqirish: %q", text)
	}
}

func TestOrderPostErrors(t *testing.T) {
	cases := []struct {
		err   error
		reply string
		step  string // "" — qoralama tashlangan
	}{
		{OrderError("CONTACT_NOT_ALLOWED"), msgOrderNoContact, stepProblem},
		{OrderError("ORDER_LIMIT"), msgOrderLimit, ""},
		{ErrBlocked, msgOrderBlocked, ""},
		{context.DeadlineExceeded, msgOrderFailed, stepConfirm},
	}
	for _, c := range cases {
		w, tg, st, ord := newOrderTest(t)
		st.known[120] = "998901234567"
		ord.postErr = c.err
		reachConfirm(t, w, tg, 120)
		if text, _ := say(t, w, tg, privateMsg(120, btnPublish)); text != c.reply {
			t.Errorf("%v: %q", c.err, text)
		}
		d := w.drafts.get(120, timeNow())
		if (c.step == "" && d != nil) || (c.step != "" && (d == nil || d.Step != c.step)) {
			t.Errorf("%v: qoralama %+v", c.err, d)
		}
	}
}

// Javob yetib bormay qayta urinilgan yoki ikkinchi nusxa — baza takroriy e'lonni yaratmaydi (PostOrder: Duplicate)
func TestOrderDuplicateNotPostedTwice(t *testing.T) {
	w, tg, st, ord := newOrderTest(t)
	notified := 0
	w.OutboxNotify = func() { notified++ }
	st.known[125] = "998901234567"
	ord.result = OrderResult{JobID: "00000000-0000-0000-0000-0000000000aa", Duplicate: true}
	reachConfirm(t, w, tg, 125)
	w.handleUpdate(context.Background(), privateMsg(125, btnPublish))
	n := len(tg.sent)
	if tg.sent[n-2].Text != msgOrderDuplicate || notified != 0 {
		t.Fatalf("takroriy: %q, bildirishnoma %d", tg.sent[n-2].Text, notified)
	}
	if title, _ := siteButton(tg.markups[n-1]); title != btnOffers {
		t.Fatalf("takliflar tugmasi yo'q: %q", tg.sent[n-1].Text)
	}
}

// Sinov holati (TELEGRAM_ORDERS=test): oqim faqat sinov raqamlariga ochiq, ularning e'loni saqlanmaydi
func TestOrderTestMode(t *testing.T) {
	w, tg, st, ord := newOrderTest(t)
	notified := 0
	w.OutboxNotify = func() { notified++ }
	w.OrderMode = OrdersTest
	w.OrderTestPhones = map[string]bool{"998909990000": true}
	st.known[201] = "998900000201" // oddiy foydalanuvchi
	st.known[202] = "998909990000" // sinov raqami

	// Oddiy foydalanuvchi: /usta va reklama havolasi — odatdagi kirish (kod), «kod noto'g'ri» emas
	if text, _ := say(t, w, tg, privateMsg(201, orderCommand)); text == msgOrderStart {
		t.Fatal("sinov holatida oddiy foydalanuvchiga oqim ochildi")
	}
	text, _ := say(t, w, tg, privateMsg(201, "/start order_instagram"))
	if text == msgOrderStart || text == msgBadCode {
		t.Fatalf("havola oddiy /start bo'lishi kerak edi: %q", text)
	}
	sentCode(t, w, st, text, "998900000201")
	// Notanish chat: salomlashuvda «Usta chaqirish» tugmasi yo'q
	if text, kb := say(t, w, tg, privateMsg(203, "/start")); text != msgHello || has(buttons(kb), btnOrder) {
		t.Fatalf("sinov holatida salom: %q %v", text, buttons(kb))
	}

	// Sinov raqami: oqim ochiq, tashrif yozilmaydi, e'lon dry-run, mijoz bazada bog'lanmaydi
	ord.result = OrderResult{Providers: 3, Admins: 1}
	if text, _ := say(t, w, tg, privateMsg(202, "/start order_instagram")); text != msgOrderStart {
		t.Fatalf("sinov raqamiga oqim ochilmadi: %q", text)
	}
	for _, s := range []string{"🔧 Santexnik", "Chilonzor", "Hammomda truba oqyapti, tezroq", "Qatortol 12", "📅 Bugun"} {
		w.handleUpdate(context.Background(), privateMsg(202, s))
	}
	text, kb := say(t, w, tg, privateMsg(202, btnPublish))
	if text != "🧪 Sinov rejimi: e'lon to'liq tekshirildi, lekin saqlanmadi va hech kimga yuborilmadi.\n\n"+
		"Haqiqiy e'londa xabar olardi: ustalar — 3, adminlar — 1." || kb == nil {
		t.Fatalf("sinov javobi: %q", text)
	}
	if len(ord.dryRuns) != 1 || !ord.dryRuns[0] || len(ord.clients) != 0 || len(ord.visits) != 0 || notified != 0 {
		t.Fatalf("dry-run: %v, mijozlar %v, tashriflar %v, bildirishnoma %d", ord.dryRuns, ord.clients, ord.visits, notified)
	}
}

// Hamma uchun yoqilganda ham sinov raqami (notanish chatdan raqam yuborsa ham) dry-run bo'ladi
func TestOrderOnModeTestPhoneIsDryRun(t *testing.T) {
	w, tg, _, ord := newOrderTest(t)
	w.OrderTestPhones = map[string]bool{"998909990000": true}
	reachConfirm(t, w, tg, 210)
	w.handleUpdate(context.Background(), privateMsg(210, btnPublish))
	u := contactMsg(210, 210, "+998 90 999 00 00")
	text, _ := say(t, w, tg, u)
	if !strings.HasPrefix(text, "🧪 Sinov rejimi") || len(ord.dryRuns) != 1 || !ord.dryRuns[0] || len(ord.clients) != 0 {
		t.Fatalf("sinov raqami: %q %v %v", text, ord.dryRuns, ord.clients)
	}
}

// O'chiq holat: hech narsa o'zgarmaydi — /usta, havola va salomlashuv avvalgidek (kirish)
func TestOrderOffMode(t *testing.T) {
	w, tg, _, ord := newOrderTest(t)
	w.OrderMode = OrdersOff
	if text, kb := say(t, w, tg, privateMsg(220, "/start")); text != msgHello || has(buttons(kb), btnOrder) {
		t.Fatalf("salom: %q", text)
	}
	if text, _ := say(t, w, tg, privateMsg(220, orderCommand)); text != msgHello {
		t.Fatalf("/usta: %q", text)
	}
	if text, _ := say(t, w, tg, privateMsg(220, btnPublish)); text != msgHello {
		t.Fatalf("eski tugma: %q", text)
	}
	if len(ord.visits) != 0 || len(ord.posted) != 0 {
		t.Fatalf("o'chiq holatda baza chaqirildi: %v %v", ord.visits, ord.posted)
	}
}

// Bot profili: faqat «on» holatida tavsifga e'lon qo'shiladi va menyu o'rnatiladi
func TestOrderBotProfileOnlyWhenPublic(t *testing.T) {
	for _, mode := range []OrderMode{OrdersOff, OrdersTest, OrdersOn} {
		w, tg, _, _ := newOrderTest(t)
		w.OrderMode = mode
		w.ensureProfile(context.Background())
		joined := strings.Join(tg.profile, "\n")
		public := mode == OrdersOn
		if strings.Contains(joined, "setMyCommands") != public || strings.Contains(joined, "Usta kerakmi") != public {
			t.Errorf("%s: profil chaqiruvlari: %v", mode, tg.profile)
		}
		if !strings.Contains(joined, "setMyDescription:"+botTexts[0].Description) && !public {
			t.Errorf("%s: eski tavsif saqlanmadi: %v", mode, tg.profile)
		}
	}
}

func TestParseOrderStart(t *testing.T) {
	cases := []struct {
		arg  string
		ok   bool
		want Attribution
	}{
		{"order", true, Attribution{}},
		{"order_instagram", true, Attribution{Source: "instagram"}},
		{"order_instagram__nov25", true, Attribution{Source: "instagram", Campaign: "nov25"}},
		{"order_tg-kanal__dekabr_aksiya", true, Attribution{Source: "tg-kanal", Campaign: "dekabr_aksiya"}},
		{"orders", false, Attribution{}},
		{"login_abc", false, Attribution{}},
		{"0a1b2c3d", false, Attribution{}},
	}
	for _, c := range cases {
		got, ok := parseOrderStart(c.arg)
		if ok != c.ok || got != c.want {
			t.Errorf("%q: %+v %v, kutilgan %+v %v", c.arg, got, ok, c.want, c.ok)
		}
	}
}

func TestSTTProviderName(t *testing.T) {
	for in, want := range map[string]string{
		"": "OpenAI", "https://api.openai.com/v1/audio/transcriptions": "OpenAI",
		"https://api.groq.com/openai/v1/audio/transcriptions": "Groq", "https://stt.example.uz/v1": "stt.example.uz",
	} {
		if got := STTProviderName(in); got != want {
			t.Errorf("%q: %q, kutilgan %q", in, got, want)
		}
	}
}

func TestOrderTitle(t *testing.T) {
	cases := map[string]string{
		"hammomdagi trubadan suv oqyapti. Tezroq": "Hammomdagi trubadan suv oqyapti",
		"Kran": "Santexnik kerak",
		"Uyimizdagi barcha rozetkalarni va o'chirgichlarni yangisiga almashtirish kerak, jami 15 ta": "",
	}
	for in, want := range cases {
		got := (&OrderDraft{Category: "Santexnik", Description: in}).Title()
		n := utf8.RuneCountInString(got)
		if n < 5 || n > 80 {
			t.Errorf("%q: sarlavha uzunligi %d: %q", in, n, got)
		}
		if want != "" && got != want {
			t.Errorf("%q: %q, kutilgan %q", in, got, want)
		}
		if want == "" && !strings.HasSuffix(got, "…") {
			t.Errorf("%q: uzun sarlavha qisqartirilmadi: %q", in, got)
		}
	}
}

func TestLocationOutsideUzbekistan(t *testing.T) {
	w, tg, _, _ := newOrderTest(t)
	for _, s := range []string{orderCommand, "🎨 Bo'yoqchi", "Olmazor", "Devorlarni bo'yash kerak, 2 xona"} {
		w.handleUpdate(context.Background(), privateMsg(130, s))
	}
	loc := privateMsg(130, "")
	loc.Message.Location = &Location{Latitude: 55.75, Longitude: 37.6} // Moskva
	if text, _ := say(t, w, tg, loc); text != msgOrderLocationBad {
		t.Fatalf("chet el joylashuvi: %q", text)
	}
}
