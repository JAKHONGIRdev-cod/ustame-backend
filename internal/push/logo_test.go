package push

import (
	"bytes"
	"context"
	"encoding/json"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDeliverAddsImageOnlyForAndroid(t *testing.T) {
	expo, got := fakeExpo(t, 200, okTickets)
	st := &fakeStore{queue: []Message{
		{ID: 1, Token: "ExponentPushToken[aaaaaaaaaaaa]", Text: "Yangi e'lon", Platform: "android", CreatedAt: time.Now()},
		{ID: 1, Token: "ExponentPushToken[bbbbbbbbbbbb]", Text: "Yangi e'lon", Platform: "ios", CreatedAt: time.Now()},
	}}
	const img = "https://example.up.railway.app/push/logo.png"
	w := &Worker{Expo: expo, Store: st, ImageURL: img}
	if failed, _ := w.deliverOnce(context.Background()); failed {
		t.Fatal("xato bo'lmasligi kerak edi")
	}
	if len(*got) != 2 {
		t.Fatalf("yuborilgan = %d, kutilgan 2", len(*got))
	}
	if rc := (*got)[0].RichContent; rc == nil || rc.Image != img {
		t.Fatalf("Android xabarida rasm bo'lishi kerak: %+v", rc)
	}
	if rc := (*got)[1].RichContent; rc != nil {
		t.Fatalf("iOS xabarida rasm bo'lmasligi kerak: %+v", rc)
	}

	// Expo'ga ketadigan JSON: Android'da richContent.image, iOS'da maydonning o'zi yo'q (omitempty)
	android, _ := json.Marshal((*got)[0])
	ios, _ := json.Marshal((*got)[1])
	if !strings.Contains(string(android), `"richContent":{"image":"`+img+`"}`) {
		t.Fatalf("Android JSON noto'g'ri: %s", android)
	}
	if strings.Contains(string(ios), "richContent") {
		t.Fatalf("iOS JSON'da richContent bo'lmasligi kerak: %s", ios)
	}
}

func TestDeliverWithoutImageURL(t *testing.T) {
	expo, got := fakeExpo(t, 200, okTickets)
	st := &fakeStore{queue: []Message{
		{ID: 1, Token: "ExponentPushToken[aaaaaaaaaaaa]", Text: "Xabar", Platform: "android", CreatedAt: time.Now()},
	}}
	w := &Worker{Expo: expo, Store: st} // ImageURL bo'sh: PUSH_IMAGE_URL=off yoki lokal
	if failed, _ := w.deliverOnce(context.Background()); failed {
		t.Fatal("xato bo'lmasligi kerak edi")
	}
	if len(*got) != 1 || (*got)[0].RichContent != nil {
		t.Fatalf("rasm bo'lmasligi kerak: %+v", *got)
	}
}

func TestImageURL(t *testing.T) {
	const domain = "ustame-backend-production-cdde.up.railway.app"
	cases := []struct{ explicit, domain, want string }{
		{"", domain, "https://" + domain + "/push/logo.png"},
		{"  ", " " + domain + " ", "https://" + domain + "/push/logo.png"},
		{"off", domain, ""},
		{" OFF ", domain, ""},
		{"https://ustame.com/push-logo.png", domain, "https://ustame.com/push-logo.png"},
		{"", "", ""}, // lokal: domen yo'q — rasmsiz
	}
	for _, c := range cases {
		if got := ImageURL(c.explicit, c.domain); got != c.want {
			t.Errorf("ImageURL(%q, %q) = %q, kutilgan %q", c.explicit, c.domain, got, c.want)
		}
	}
}

func TestServeLogo(t *testing.T) {
	rec := httptest.NewRecorder()
	ServeLogo(rec, httptest.NewRequest(http.MethodGet, LogoPath, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "image/png" {
		t.Fatalf("Content-Type = %q", ct)
	}
	if cc := rec.Header().Get("Cache-Control"); !strings.HasPrefix(cc, "public") {
		t.Fatalf("Cache-Control = %q", cc)
	}
	// FCM rasmni 5 soniya kutadi va 1 MB dan kattasini olmaydi — fayl kichik va haqiqiy PNG bo'lsin
	body := rec.Body.Bytes()
	if len(body) == 0 || len(body) > 100<<10 {
		t.Fatalf("rasm hajmi %d bayt (0 < x <= 100 KB bo'lishi kerak)", len(body))
	}
	cfg, err := png.DecodeConfig(bytes.NewReader(body))
	if err != nil {
		t.Fatalf("PNG o'qilmadi: %v", err)
	}
	if cfg.Width != cfg.Height || cfg.Width < 256 {
		t.Fatalf("rasm %dx%d — kvadrat va kamida 256 px bo'lishi kerak", cfg.Width, cfg.Height)
	}

	head := httptest.NewRecorder()
	ServeLogo(head, httptest.NewRequest(http.MethodHead, LogoPath, nil))
	if head.Code != http.StatusOK || head.Body.Len() != 0 {
		t.Fatalf("HEAD: status %d, tana %d bayt", head.Code, head.Body.Len())
	}
}
