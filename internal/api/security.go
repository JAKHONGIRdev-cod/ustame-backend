package api

import (
	"net/http"
)

const (
	// Bitta IP'dan soatiga kodni tekshirish va Telegram orqali kirishni boshlash. Mobil operatorlarda ko'p
	// abonent bitta IP'dan chiqadi — chegara keng; kod tanlab topishga (har kodga 5 urinish) va bazani
	// so'rovlar bilan to'ldirishga qarshi qo'shimcha to'siq.
	verifyPerIPPerHour  = 120
	tgStartPerIPPerHour = 120
	// Tokensiz RPC (saytdagi material narxlari): oddiy mehmon soatiga bir necha marta ochadi
	anonPerIPPerHour = 600
)

// securityHeaders — barcha API javoblariga himoya sarlavhalari. Javoblar JSON yoki rasm: hech biri sahifa
// sifatida ochilmasligi, boshqa saytga ramkada joylanmasligi va keshda qolmasligi kerak
// (/api/files o'zining Cache-Control'ini qo'yadi — keyin qo'yilgani ustun).
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}
