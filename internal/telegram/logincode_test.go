package telegram

import (
	"context"
	"regexp"
	"strings"
	"testing"

	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/auth"
)

var codeRe = regexp.MustCompile(`\b\d{6}\b`)

// newCodeTest — kod berish yoqilgan bot (prod'dagi kabi OTPSecret bor)
func newCodeTest(t *testing.T) (*Worker, *fakeTG, *fakeStore) {
	w, tg, st := newTest(t)
	w.OTPSecret = []byte("test-otp-secret")
	return w, tg, st
}

// sentCode — xabardagi 6 xonali kod va u bazaga to'g'ri xesh bilan yozilganini tekshiradi
func sentCode(t *testing.T, w *Worker, st *fakeStore, text, phone string) string {
	t.Helper()
	code := codeRe.FindString(text)
	if code == "" {
		t.Fatalf("xabarda kod yo'q: %q", text)
	}
	hashes := st.issued[phone]
	if len(hashes) == 0 || hashes[len(hashes)-1] != auth.HashCode(w.OTPSecret, phone, code) {
		t.Fatalf("kod %s raqamiga to'g'ri yozilmagan: %v", phone, hashes)
	}
	return code
}

// Havola eskirgan yoki umuman yo'q — odam baribir kiradi: raqamni yuboradi, bot kod beradi
func TestContactWithoutSessionGetsCode(t *testing.T) {
	w, tg, st := newCodeTest(t)
	w.handleUpdate(context.Background(), contactMsg(81, 81, "+998 90 123-45-67"))

	if len(tg.sent) != 1 || !strings.HasPrefix(tg.sent[0].Text, "🔑") {
		t.Fatalf("yuborilgan: %v", tg.sent)
	}
	sentCode(t, w, st, tg.sent[0].Text, "998901234567")
}

func TestExpiredLinkAsksContactThenCode(t *testing.T) {
	w, tg, st := newCodeTest(t)
	ctx := context.Background()
	w.handleUpdate(ctx, privateMsg(82, "/start login_eskikod"))
	if tg.sent[0].Text != msgLoginExpiredAsk || !askedForContact(tg.markups[0]) {
		t.Fatalf("eskirgan havolada raqam so'ralishi kerak: %v %v", tg.sent, tg.markups)
	}
	w.handleUpdate(ctx, contactMsg(82, 82, "998901234567"))
	sentCode(t, w, st, tg.sent[1].Text, "998901234567")
}

func TestPlainStartUnknownChatAsksContact(t *testing.T) {
	w, tg, st := newCodeTest(t)
	w.handleUpdate(context.Background(), privateMsg(83, "/start"))
	if tg.sent[0].Text != msgHello || !askedForContact(tg.markups[0]) || len(st.issued) != 0 {
		t.Fatalf("yuborilgan: %v %v", tg.sent, tg.markups)
	}
	// Raqamni qo'lda yozsa ham — tugmani ko'rsatamiz
	w.handleUpdate(context.Background(), privateMsg(83, "+998901234567"))
	if tg.sent[1].Text != msgHello || !askedForContact(tg.markups[1]) {
		t.Fatalf("matnga ham tugma bilan javob kerak: %v", tg.sent)
	}
}

func TestPlainStartKnownChatGetsCodeAtOnce(t *testing.T) {
	w, tg, st := newCodeTest(t)
	st.known[84] = "998901112233"
	w.handleUpdate(context.Background(), privateMsg(84, "/start"))
	if len(tg.sent) != 1 || askedForContact(tg.markups[0]) {
		t.Fatalf("tanish chat'dan raqam so'ralmasligi kerak: %v", tg.sent)
	}
	sentCode(t, w, st, tg.sent[0].Text, "998901112233")
}

// Havola orqali tasdiqlanganda ham zaxira kod: brauzer yopilib qolgan bo'lsa ham kiradi
func TestLoginDoneIncludesBackupCode(t *testing.T) {
	w, tg, st := newCodeTest(t)
	st.loginCodes["k1"] = true
	ctx := context.Background()
	w.handleUpdate(ctx, privateMsg(85, "/start login_k1"))
	w.handleUpdate(ctx, contactMsg(85, 85, "998901234567"))

	if st.verified[85] != "998901234567" {
		t.Fatalf("havola orqali kirish tasdiqlanishi kerak: %v", st.verified)
	}
	if !strings.HasPrefix(tg.sent[1].Text, "✅") {
		t.Fatalf("javob: %q", tg.sent[1].Text)
	}
	sentCode(t, w, st, tg.sent[1].Text, "998901234567")
}

func TestKnownChatLinkIncludesBackupCode(t *testing.T) {
	w, tg, st := newCodeTest(t)
	st.loginCodes["k2"] = true
	st.known[86] = "998901112233"
	w.handleUpdate(context.Background(), privateMsg(86, "/start login_k2"))
	if st.verified[86] != "998901112233" {
		t.Fatalf("verified = %v", st.verified)
	}
	sentCode(t, w, st, tg.sent[0].Text, "998901112233")
}

func TestCodeLimit(t *testing.T) {
	w, tg, st := newCodeTest(t)
	st.codeLimited = true
	w.handleUpdate(context.Background(), contactMsg(87, 87, "998901234567"))
	if tg.sent[0].Text != msgCodeLimit {
		t.Fatalf("javob: %q", tg.sent[0].Text)
	}
}

// Begona kontakt va guruh — kod hech qachon berilmaydi
func TestNoCodeForForeignContactOrGroup(t *testing.T) {
	w, tg, st := newCodeTest(t)
	ctx := context.Background()
	w.handleUpdate(ctx, contactMsg(88, 999, "998901234567"))
	g := contactMsg(-100, -100, "998901234567")
	g.Message.Chat.Type = "group"
	w.handleUpdate(ctx, g)
	gs := privateMsg(-100, "/start")
	gs.Message.Chat.Type = "group"
	w.handleUpdate(ctx, gs)

	if len(st.issued) != 0 {
		t.Fatalf("kod berilmasligi kerak: %v", st.issued)
	}
	if tg.sent[0].Text != msgLoginNotOwn {
		t.Fatalf("yuborilgan: %v", tg.sent)
	}
}

// siteButton — xabardagi inline tugma: matni va havolasi ("" — tugma yo'q)
func siteButton(markup any) (text, url string) {
	m, _ := markup.(map[string]any)
	rows, _ := m["inline_keyboard"].([]any)
	if len(rows) == 0 {
		return "", ""
	}
	row, _ := rows[0].([]any)
	if len(row) == 0 {
		return "", ""
	}
	btn, _ := row[0].(map[string]any)
	text, _ = btn["text"].(string)
	url, _ = btn["url"].(string)
	return text, url
}

// Saytdan kelgan: tasdiqlangach "Ustame'ga qaytish" tugmasi bir martalik kod bilan saytni ochadi
func TestSiteButtonCarriesCode(t *testing.T) {
	w, tg, st := newCodeTest(t)
	st.loginCodes["k1"] = true
	ctx := context.Background()
	w.handleUpdate(ctx, privateMsg(91, "/start login_k1"))
	w.handleUpdate(ctx, contactMsg(91, 91, "998901234567"))

	code := sentCode(t, w, st, tg.sent[1].Text, "998901234567")
	text, url := siteButton(tg.markups[1])
	if text != btnBack || url != "https://ustame.com/tg-login#998901234567."+code {
		t.Fatalf("tugma: %q %q", text, url)
	}

	// Havolasiz kelgan (kod so'ragan) — "Ustame'ga kirish" tugmasi
	w.handleUpdate(ctx, contactMsg(92, 92, "998907654321"))
	code = sentCode(t, w, st, tg.sent[2].Text, "998907654321")
	if text, url := siteButton(tg.markups[2]); text != btnLogin || url != "https://ustame.com/tg-login#998907654321."+code {
		t.Fatalf("tugma: %q %q", text, url)
	}
}

// Ilovadan kelgan (login_<kod>_a): tugma yo'q — u ilovani emas, saytni ochardi; kod matnda qoladi
func TestAppLoginHasNoSiteButton(t *testing.T) {
	w, tg, st := newCodeTest(t)
	st.loginCodes["k7"] = true
	ctx := context.Background()
	w.handleUpdate(ctx, privateMsg(93, "/start login_k7_a"))
	w.handleUpdate(ctx, contactMsg(93, 93, "998901234567"))

	if st.verified[93] != "998901234567" {
		t.Fatalf("_a belgisi koddan ajratilishi kerak: verified=%v", st.verified)
	}
	sentCode(t, w, st, tg.sent[1].Text, "998901234567")
	if _, url := siteButton(tg.markups[1]); url != "" {
		t.Fatalf("ilovadan kelganga sayt tugmasi chiqmasligi kerak: %q", url)
	}
	if m, _ := tg.markups[1].(map[string]any); m["remove_keyboard"] != true {
		t.Errorf("klaviatura yopilishi kerak: %v", tg.markups[1])
	}

	// Keyin havolasiz /start — endi saytdan deb hisoblanadi (belgi tozalanadi)
	st.known[93] = "998901234567"
	w.handleUpdate(ctx, privateMsg(93, "/start"))
	if _, url := siteButton(tg.markups[2]); url == "" {
		t.Fatalf("havolasiz /start'da tugma bo'lishi kerak")
	}
}

// Ilova + kirill: login_<kod>_a_c — ikkala belgi ham o'qiladi
func TestAppAndCyrillicSuffixes(t *testing.T) {
	w, tg, st := newCodeTest(t)
	st.loginCodes["k8"] = true
	w.handleUpdate(context.Background(), privateMsg(94, "/start login_k8_a_c"))
	if !st.loginChats[94] {
		t.Fatalf("kod belgilarsiz o'qilishi kerak edi")
	}
	if tg.sent[0].Text == msgLoginAsk || !askedForContact(tg.markups[0]) {
		t.Fatalf("javob kirillda va raqam tugmasi bilan bo'lishi kerak: %q", tg.sent[0].Text)
	}
}
