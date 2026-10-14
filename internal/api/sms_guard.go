package api

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"
)

const (
	// Bitta IP'dan soatiga kod so'rash. Mobil operatorlarda ko'p abonent bitta IP orqali chiqadi,
	// shuning uchun chegara keng: oddiy foydalanuvchi bunga yetmaydi, bot esa ko'p raqamni aylantira olmaydi.
	smsPerIPPerHour = 20
	// Adminlarga takroriy ogohlantirish oralig'i
	smsAlertEvery = 6 * time.Hour
)

// smsAlert — kunlik SMS chegarasining 80% iga yetilganda adminlarga (Telegram va push) ogohlantirish,
// smsAlertEvery da ko'pi bilan bir marta.
type smsAlert struct {
	mu   sync.Mutex
	last time.Time
}

func (a *smsAlert) due(now time.Time) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if now.Sub(a.last) < smsAlertEvery {
		return false
	}
	a.last = now
	return true
}

func (s *Server) testPhoneList() []string {
	list := make([]string, 0, len(s.cfg.TestPhones))
	for p := range s.cfg.TestPhones {
		list = append(list, p)
	}
	return list
}

func (s *Server) alertSMSLimit(sent int) {
	if !s.smsAlert.due(time.Now()) {
		return
	}
	msg := fmt.Sprintf("⚠️ SMS: 24 soatda %d ta kod yuborildi (chegara %d). Hujum bo'lishi mumkin — "+
		"Eskiz balansini tekshiring. Chegaraga yetganda faqat Telegram orqali kirish ishlaydi (Railway: SMS_DAILY_LIMIT).",
		sent, s.cfg.SMSDailyLimit)
	log.Print(msg)
	// So'rov tugasa ham xabar yozilsin
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := s.db.Exec(ctx, `
		select queue_notification(u.id, $1, '/admin')
		from users u where u.is_admin and u.blocked_at is null and u.deleted_at is null`, msg); err != nil {
		log.Printf("sms alert: %v", err)
		return
	}
	s.Outbox.Notify()
}
