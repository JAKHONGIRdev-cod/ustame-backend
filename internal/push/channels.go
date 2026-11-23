package push

import "strings"

// Android bildirishnoma kanallari (2026-11-17). Ilova (src/lib/push.ts) ularni yaratadi va tokenni
// channels=1 bilan ro'yxatdan o'tkazadi; eski ilovalarda faqat "default" kanali bor.
const (
	ChannelDefault   = "default"
	ChannelJobs      = "jobs"      // yangi e'lon, shoshilinch, shaxsiy taklif — eng baland, o'z ovozi
	ChannelMessages  = "messages"  // taklif, chat, shartnoma, nizo — tepadan tushadi, ovozli
	ChannelReminders = "reminders" // baho, eski e'lon, profilni to'ldirish — jim
	// ChannelAdmin — admin xabarlari (2026-11-23): ilova uni yaratib tokenni channels=2 bilan ro'yxatdan o'tkazganda;
	// id "admin", nomi "Admin xabarlari", HIGH, o'z ovozi (ilova tomoni — src/lib/push.ts).
	ChannelAdmin = "admin"
)

// AdminChannelVersion — "admin" kanali bor ilova versiyasi (push_tokens.channels >= 2)
const AdminChannelVersion = 2

// Xabar matnining boshidagi belgi bo'yicha (sql/app.sql dagi queue_notification matnlari)
var (
	jobPrefixes      = []string{"🆕", "🚨", "🔔"}
	reminderPrefixes = []string{"📸", "📅", "⭐"}
)

// channelFor — xabar qaysi kanalga tushadi. channels — tokendagi kanal versiyasi (push_tokens.channels):
// 0 bo'lsa (eski ilova) doim "default", aks holda turiga qarab. Admin xabarlari (aud="admin") — ilovada
// "admin" kanali bo'lsa (channels >= 2) o'sha yerga, aks holda oddiy qoida.
func channelFor(channels int, link *string, text, aud string) string {
	if channels < 1 {
		return ChannelDefault
	}
	if aud == "admin" && channels >= AdminChannelVersion {
		return ChannelAdmin
	}
	t := strings.TrimSpace(text)
	for _, p := range jobPrefixes {
		if strings.HasPrefix(t, p) {
			return ChannelJobs
		}
	}
	for _, p := range reminderPrefixes {
		if strings.HasPrefix(t, p) {
			return ChannelReminders
		}
	}
	if link != nil && (*link == "/profile" || strings.Contains(*link, "review=1")) {
		return ChannelReminders
	}
	return ChannelMessages
}
