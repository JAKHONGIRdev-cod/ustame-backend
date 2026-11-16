package push

import "strings"

// Android bildirishnoma kanallari (2026-11-17). Ilova (src/lib/push.ts) ularni yaratadi va tokenni
// channels=1 bilan ro'yxatdan o'tkazadi; eski ilovalarda faqat "default" kanali bor.
const (
	ChannelDefault   = "default"
	ChannelJobs      = "jobs"      // yangi e'lon, shoshilinch, shaxsiy taklif — eng baland, o'z ovozi
	ChannelMessages  = "messages"  // taklif, chat, shartnoma, nizo — tepadan tushadi, ovozli
	ChannelReminders = "reminders" // baho, eski e'lon, profilni to'ldirish — jim
)

// Xabar matnining boshidagi belgi bo'yicha (sql/app.sql dagi queue_notification matnlari)
var (
	jobPrefixes      = []string{"🆕", "🚨", "🔔"}
	reminderPrefixes = []string{"📸", "📅", "⭐"}
)

// channelFor — xabar qaysi kanalga tushadi. channels — tokendagi kanal versiyasi (push_tokens.channels):
// 0 bo'lsa (eski ilova) doim "default", aks holda turiga qarab.
func channelFor(channels int, link *string, text string) string {
	if channels < 1 {
		return ChannelDefault
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
