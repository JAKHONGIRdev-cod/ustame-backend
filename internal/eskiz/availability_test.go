package eskiz

import (
	"errors"
	"testing"
	"time"
)

func TestParseRole(t *testing.T) {
	cases := map[string]string{
		`{"data":{"role":"test","balance":2220}}`: "test",
		`{"role":"user"}`:                         "user",
	}
	for in, want := range cases {
		got, err := parseRole([]byte(in))
		if err != nil || got != want {
			t.Errorf("parseRole(%s) = %q, %v; kutilgan %q", in, got, err, want)
		}
	}
	if _, err := parseRole([]byte(`{"data":{}}`)); err == nil {
		t.Error("rolsiz javob xato berishi kerak")
	}
}

func TestAvailabilityCaches(t *testing.T) {
	var a availability
	calls := 0
	now := time.Now()
	fetch := func() (bool, error) { calls++; return false, nil }

	if a.get(now, fetch) || a.get(now.Add(5*time.Minute), fetch) {
		t.Fatal("test rolida SMS yuborilmasligi kerak")
	}
	if calls != 1 {
		t.Fatalf("10 daqiqa ichida Eskiz qayta so'ralmasligi kerak, so'rovlar: %d", calls)
	}
	a.get(now.Add(11*time.Minute), func() (bool, error) { calls++; return true, nil })
	if calls != 2 || !a.ok {
		t.Fatalf("muddat o'tgach holat yangilanishi kerak: calls=%d ok=%v", calls, a.ok)
	}
}

func TestAvailabilityErrorDoesNotBlock(t *testing.T) {
	var a availability
	if !a.get(time.Now(), func() (bool, error) { return false, errors.New("tarmoq") }) {
		t.Fatal("Eskiz javob bermasa, SMS to'silmasligi kerak")
	}
	if !a.checked.IsZero() {
		t.Fatal("xato javob eslab qolinmasligi kerak")
	}
}

func TestCanSendOTPTestMode(t *testing.T) {
	c := &Client{TestMode: true}
	if c.CanSendOTP(t.Context()) {
		t.Fatal("TestMode'da kodli SMS yuborilmaydi")
	}
}
