package auth

import "testing"

// Node usta-api (crypto.createHmac / jose SignJWT) chiqargan qiymatlar: Go versiyasi ular bilan
// mos bo'lishi shart, aks holda bazadagi kodlar va telefonlardagi tokenlar ishlamay qoladi.
const (
	nodeHash  = "0ef44b0176335d368b4ddfb82103b0c75edc70e831a60b01d337741199c4dec8"
	nodeToken = "eyJhbGciOiJIUzI1NiJ9.eyJ0diI6Mywic3ViIjoiZjA4MTdlMzgtNGZkMy00ZWYzLWEwMDMtZDBhYjY4OTAzYTE5IiwiaWF0IjoxNzkwOTI3NTExLCJleHAiOjQ5NDY2ODc1MTF9.rLehLfNJIDcSN9xbcf7gHyGzy289HeWTRSqFkRX2uG8"
)

func TestHashCodeMatchesNode(t *testing.T) {
	if got := HashCode([]byte("test-otp-secret"), "998901234567", "123456"); got != nodeHash {
		t.Fatalf("hash = %s, want %s", got, nodeHash)
	}
}

func TestParseNodeToken(t *testing.T) {
	sub, tv, err := ParseToken([]byte("test-jwt-secret"), nodeToken)
	if err != nil {
		t.Fatal(err)
	}
	if sub != "f0817e38-4fd3-4ef3-a003-d0ab68903a19" || tv != 3 {
		t.Fatalf("sub=%s tv=%d", sub, tv)
	}
	if _, _, err := ParseToken([]byte("boshqa-kalit"), nodeToken); err == nil {
		t.Fatal("noto'g'ri kalit bilan token qabul qilindi")
	}
}

func TestSignAndParse(t *testing.T) {
	tok, err := SignToken([]byte("k"), "user-1", 7)
	if err != nil {
		t.Fatal(err)
	}
	sub, tv, err := ParseToken([]byte("k"), tok)
	if err != nil || sub != "user-1" || tv != 7 {
		t.Fatalf("sub=%s tv=%d err=%v", sub, tv, err)
	}
}

func TestNormalizePhone(t *testing.T) {
	for in, want := range map[string]string{
		"90 123 45 67":    "998901234567",
		"+998901234567":   "998901234567",
		"998-90-123-4567": "998901234567",
	} {
		if got, err := NormalizePhone(in); err != nil || got != want {
			t.Errorf("%q -> %q, %v", in, got, err)
		}
	}
	for _, bad := range []string{"", "12345", "+1 202 555 0100"} {
		if _, err := NormalizePhone(bad); err == nil {
			t.Errorf("%q qabul qilindi", bad)
		}
	}
}
