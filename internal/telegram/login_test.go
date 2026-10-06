package telegram

import (
	"context"
	"testing"
)

func privateMsg(chat int64, text string) Update {
	u := update(chat, text)
	u.Message.Chat.Type = "private"
	u.Message.From = &Sender{ID: chat}
	return u
}

func contactMsg(chat, contactOwner int64, phone string) Update {
	u := privateMsg(chat, "")
	u.Message.Contact = &Contact{PhoneNumber: phone, UserID: contactOwner}
	return u
}

// askedForContact — xabar "Raqamni yuborish" (request_contact) tugmasi bilan ketganmi.
func askedForContact(markup any) bool {
	m, ok := markup.(map[string]any)
	if !ok {
		return false
	}
	rows, _ := m["keyboard"].([]any)
	if len(rows) == 0 {
		return false
	}
	row, _ := rows[0].([]any)
	if len(row) == 0 {
		return false
	}
	btn, _ := row[0].(map[string]any)
	return btn["request_contact"] == true
}

func TestLoginFlow(t *testing.T) {
	w, tg, st := newTest(t)
	st.loginCodes["k1"] = true
	ctx := context.Background()

	w.handleUpdate(ctx, privateMsg(50, "/start login_k1"))
	w.handleUpdate(ctx, contactMsg(50, 50, "+998 90 123-45-67"))

	if got := st.verified[50]; got != "998901234567" {
		t.Fatalf("tasdiqlangan raqam = %q", got)
	}
	if len(tg.sent) != 2 || tg.sent[0].Text != msgLoginAsk || tg.sent[1].Text != msgLoginDone {
		t.Fatalf("yuborilgan: %v", tg.sent)
	}
	if !askedForContact(tg.markups[0]) {
		t.Errorf("birinchi javobda raqam so'raydigan tugma bo'lishi kerak: %v", tg.markups[0])
	}
	if m, _ := tg.markups[1].(map[string]any); m["remove_keyboard"] != true {
		t.Errorf("tasdiqlangach klaviatura yopilishi kerak: %v", tg.markups[1])
	}
}

func TestLoginRejectsForeignContact(t *testing.T) {
	w, tg, st := newTest(t)
	st.loginCodes["k2"] = true
	ctx := context.Background()

	w.handleUpdate(ctx, privateMsg(60, "/start login_k2"))
	w.handleUpdate(ctx, contactMsg(60, 999, "998901234567")) // boshqa odamning kontakti

	if len(st.verified) != 0 {
		t.Fatalf("begona kontakt qabul qilinmasligi kerak: %v", st.verified)
	}
	if last := tg.sent[len(tg.sent)-1].Text; last != msgLoginNotOwn {
		t.Errorf("javob = %q", last)
	}
	if !st.loginChats[60] {
		t.Error("kirish kutilayotgan holatda qolishi kerak (o'z raqamini yuborishi mumkin)")
	}
}

func TestLoginRejectsNonUzPhone(t *testing.T) {
	w, tg, st := newTest(t)
	st.loginCodes["k3"] = true
	ctx := context.Background()

	w.handleUpdate(ctx, privateMsg(70, "/start login_k3"))
	w.handleUpdate(ctx, contactMsg(70, 70, "+7 912 345 67 89"))

	if len(st.verified) != 0 || tg.sent[len(tg.sent)-1].Text != msgLoginNotUz {
		t.Fatalf("verified=%v sent=%v", st.verified, tg.sent)
	}
}

func TestLoginBadCodeAndNoSession(t *testing.T) {
	w, tg, st := newTest(t)
	ctx := context.Background()

	w.handleUpdate(ctx, privateMsg(80, "/start login_eskikod"))
	w.handleUpdate(ctx, contactMsg(81, 81, "998901234567")) // /start bosilmagan chat

	if len(st.verified) != 0 {
		t.Fatalf("verified = %v", st.verified)
	}
	if tg.sent[0].Text != msgLoginBadCode || tg.sent[1].Text != msgLoginNoSession {
		t.Fatalf("yuborilgan: %v", tg.sent)
	}
}

func TestLoginIgnoredInGroups(t *testing.T) {
	w, tg, st := newTest(t)
	st.loginCodes["k4"] = true
	ctx := context.Background()

	u := privateMsg(-100, "/start login_k4")
	u.Message.Chat.Type = "group"
	w.handleUpdate(ctx, u)
	c := contactMsg(-100, -100, "998901234567")
	c.Message.Chat.Type = "group"
	w.handleUpdate(ctx, c)

	if len(st.loginChats) != 0 || len(st.verified) != 0 || len(tg.sent) != 0 {
		t.Fatalf("guruhda kirish ishlamasligi kerak: chats=%v verified=%v sent=%v", st.loginChats, st.verified, tg.sent)
	}
}

func TestNotificationStartStillWorks(t *testing.T) {
	w, tg, st := newTest(t)
	st.codes["abc"] = true
	w.handleUpdate(context.Background(), privateMsg(90, "/start abc"))
	if !st.linked[90] || tg.sent[0].Text != msgLinked {
		t.Fatalf("bildirishnoma ulash buzilmasligi kerak: linked=%v sent=%v", st.linked, tg.sent)
	}
}

func TestUzPhone(t *testing.T) {
	cases := map[string]string{
		"998901234567":       "998901234567",
		"+998901234567":      "998901234567",
		"+998 (90) 123-4567": "998901234567",
		"901234567":          "",
		"+79123456789":       "",
		"9989012345678":      "",
	}
	for in, want := range cases {
		got, ok := uzPhone(in)
		if got != want || ok != (want != "") {
			t.Errorf("uzPhone(%q) = %q, %v; kutilgan %q", in, got, ok, want)
		}
	}
}
