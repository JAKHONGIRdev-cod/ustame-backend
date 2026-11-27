package push

import (
	"bytes"
	_ "embed"
	"net/http"
	"strings"
	"time"
)

// logoPNG — Android bildirishnomasining o'ng tomonidagi rangli logo (512x512, qora fonda U + kaska).
//
// Nega server beradi: Android'da ilova yopiq yoki orqa fonda bo'lsa, bildirishnomani ilova emas, telefondagi FCM
// kutubxonasi chizadi (Expo title/body bor xabarni FCM'ga "notification message" qilib yuboradi). U ilovaga
// qo'yilgan large icon'ni (manifestdagi expo.modules.notifications.large_notification_icon) o'qimaydi — o'ng
// tomondagi rasmni faqat xabardagi havoladan oladi (Expo richContent.image → FCM notification.image). Ilova ochiq
// turganda ham expo-notifications shu rasmni large icon qiladi. Kichik belgi esa Android qoidasiga ko'ra har doim
// bir rangli oq siluet (rangi app.json'dagi color bilan bo'yaladi).
//
// Rasm bo'lsa FCM bildirishnoma ochilganda (pastga tortilganda) uni katta rasm qilib ko'rsatadi, matn bitta qatorda
// qoladi — bu FCM'ning o'zgarmas uslubi. O'chirish kerak bo'lsa: PUSH_IMAGE_URL=off.
//
//go:embed logo.png
var logoPNG []byte

// LogoPath — rasm shu yo'lda beriladi (api.Server.Handler).
const LogoPath = "/push/logo.png"

// ServeLogo — GET /push/logo.png. FCM rasmni har bildirishnomada qayta yuklaydi (keshlamaydi), 5 soniyada
// yuklanmasa bildirishnoma rasmsiz chiqadi — fayl kichik (~25 KB) bo'lishi shuning uchun.
func ServeLogo(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "public, max-age=86400")
	http.ServeContent(w, r, "logo.png", time.Time{}, bytes.NewReader(logoPNG))
}

// ImageURL — bildirishnomaga biriktiriladigan rasm havolasi. explicit (PUSH_IMAGE_URL) ustun: "off" — rasmsiz,
// boshqa qiymat — shu havola. Bo'sh bo'lsa serverning o'z domenidagi LogoPath (Railway RAILWAY_PUBLIC_DOMAIN'ni
// o'zi beradi); domen yo'q bo'lsa (lokal ishga tushirish) — rasmsiz.
func ImageURL(explicit, publicDomain string) string {
	switch v := strings.TrimSpace(explicit); {
	case strings.EqualFold(v, "off"):
		return ""
	case v != "":
		return v
	}
	if d := strings.TrimSpace(publicDomain); d != "" {
		return "https://" + d + LogoPath
	}
	return ""
}
