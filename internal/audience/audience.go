// Package audience — bildirishnoma qaysi rol uchun (notification_outbox.audience, 2026-11-23) va push/Telegram
// matni boshiga qo'yiladigan belgi. Rolni SQL aniqlaydi (queue_notification / _notification_audience).
package audience

const (
	Admin    = "admin"
	Provider = "provider"
	Client   = "client"
	Shop     = "shop"
)

// Prefix — matn boshidagi rol belgisi.
//   - Admin xabarlari doim belgilanadi: adminlarning ko'pi usta ham, admin xabari oddiy xabarlar orasida yo'qolmasin.
//   - Usta / mijoz / do'kon belgisi faqat bir nechta rolli odamga (masalan usta ham e'lon bergan) — qolganlarga shovqin.
func Prefix(aud string, multiRole bool) string {
	switch {
	case aud == Admin:
		return "🛡 Admin · "
	case !multiRole:
		return ""
	case aud == Provider:
		return "🔧 Usta · "
	case aud == Client:
		return "🏠 Mijoz · "
	case aud == Shop:
		return "🏪 Do'kon · "
	}
	return ""
}
