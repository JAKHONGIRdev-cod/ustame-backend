package telegram

import (
	"context"
	"fmt"
	"log"
	"strings"
	"unicode/utf8"

	"github.com/JAKHONGIRdev-cod/ustame-backend/internal/cyrillic"
)

// Ustalar so'rovnomasi Telegram'da: Telegram orqali kirgandan biroz keyin bot savollarni bittadan poll qilib
// yuboradi (javob berilgach — keyingisi), oxirgi ochiq savolga matn bilan javob kutadi. Javoblar ilovadagi
// so'rovnoma bilan bir joyga — survey_responses (pros_v1) ga yoziladi, admin/surveys natijalarida birga ko'rinadi.
// Savollar va matnlar: survey_texts.go (ilova i18n'idan yasalgan).

const prosSurveyKey = "pros_v1"

// multi savolda nechtagacha belgilash so'raladi (ilovadagi bilan bir xil)
const surveyPickMax = 3

type surveyOption struct {
	ID   string
	Text map[string]string
}

type surveyQuestion struct {
	ID      string
	Kind    string // single | multi | text
	Text    map[string]string
	Options []surveyOption
}

// SurveyRef — yuborilgan bitta savol (telegram_survey_polls qatori).
type SurveyRef struct {
	PollID   string // Telegram poll id; ochiq savolda "t:<chat_id>:<savol>"
	ChatID   int64
	Phone    string
	Survey   string
	Question string
	Lang     string // uz | uzc | ru
}

var (
	surveyNotMaster = map[string]string{
		"uz": "Usta bo'lmasangiz, bu so'rovnomaga e'tibor bermang.",
		"ru": "Если вы не мастер, просто пропустите этот опрос.",
	}
	surveyIntroIcon = "📝 "
)

// surveyLang: users.lang -> savollar tili (en uchun o'zbekcha)
func surveyLang(lang string) string {
	switch lang {
	case "ru", "uzc":
		return lang
	}
	return "uz"
}

// st — matn kerakli tilda; uzc — o'zbekcha matn kirillga o'giriladi
func st(m map[string]string, lang string) string {
	if lang == "ru" {
		if s, ok := m["ru"]; ok {
			return s
		}
	}
	s := m["uz"]
	if lang == "uzc" {
		return cyrillic.Convert(s)
	}
	return s
}

// scheduleSurvey — kirishdan keyin (SurveyAfterLogin kechikish bilan) so'rovnomani boshlaydi. 0 — o'chiq.
func (w *Worker) scheduleSurvey(ctx context.Context, chatID int64, phone string) {
	if w.SurveyAfterLogin <= 0 {
		return
	}
	go func() {
		if !sleep(ctx, w.SurveyAfterLogin) {
			return
		}
		w.startSurvey(ctx, chatID, phone)
	}()
}

// startSurvey — avval boshlanmagan va ilovada javob berilmagan bo'lsa: kirish matni va birinchi savol.
func (w *Worker) startSurvey(ctx context.Context, chatID int64, phone string) {
	lang, start, err := w.Store.SurveyLang(ctx, phone, prosSurveyKey)
	if err != nil {
		log.Printf("telegram: so'rovnoma holati o'qilmadi: %v", err)
		return
	}
	if !start {
		return
	}
	lang = surveyLang(lang)
	intro := surveyIntroIcon + st(surveyTexts["intro"], lang) + "\n\n" + st(surveyTexts["introText"], lang) + "\n\n" +
		st(surveyNotMaster, lang)
	w.send(ctx, chatID, intro, nil)
	w.sendSurveyQuestion(ctx, SurveyRef{ChatID: chatID, Phone: phone, Survey: prosSurveyKey, Lang: lang}, 0)
}

// sendSurveyQuestion — idx-savolni yuboradi (poll yoki ochiq savol) va bazaga yozadi.
func (w *Worker) sendSurveyQuestion(ctx context.Context, ref SurveyRef, idx int) {
	if idx >= len(prosSurvey) {
		return
	}
	q := prosSurvey[idx]
	title := fmt.Sprintf("%d/%d. %s", idx+1, len(prosSurvey), st(q.Text, ref.Lang))
	ref.Question = q.ID
	switch q.Kind {
	case "text":
		ref.PollID = fmt.Sprintf("t:%d:%s", ref.ChatID, q.ID)
		markup := map[string]any{"force_reply": true, "input_field_placeholder": st(surveyTexts["textPlaceholder"], ref.Lang)}
		if err := w.TG.SendMessageMarkup(ctx, ref.ChatID, title+"\n\n("+st(surveyTexts["optional"], ref.Lang)+")", markup); err != nil {
			log.Printf("telegram: so'rovnoma savoli yuborilmadi: %v", err)
			return
		}
	default:
		if q.Kind == "multi" {
			title += " — " + strings.ReplaceAll(st(surveyTexts["pickUpTo"], ref.Lang), "{n}", fmt.Sprint(surveyPickMax))
		}
		opts := make([]string, len(q.Options))
		for i, o := range q.Options {
			opts[i] = st(o.Text, ref.Lang)
		}
		id, err := w.TG.SendPoll(ctx, ref.ChatID, title, opts, q.Kind == "multi")
		if err != nil || id == "" {
			log.Printf("telegram: so'rovnoma poll'i yuborilmadi: %v", err)
			return
		}
		ref.PollID = id
	}
	if err := w.Store.SaveSurveyQuestion(ctx, ref); err != nil {
		log.Printf("telegram: so'rovnoma savoli saqlanmadi: %v", err)
	}
}

func surveyIndex(id string) int {
	for i, q := range prosSurvey {
		if q.ID == id {
			return i
		}
	}
	return -1
}

// handlePollAnswer — poll'dagi ovozni saqlaydi; birinchi marta javob berilgan bo'lsa keyingi savolni yuboradi.
func (w *Worker) handlePollAnswer(ctx context.Context, pa *PollAnswer) {
	if len(pa.OptionIDs) == 0 {
		return // ovozini qaytarib oldi
	}
	ref, ok, err := w.Store.SurveyPoll(ctx, pa.PollID)
	if err != nil {
		log.Printf("telegram: so'rovnoma poll'i o'qilmadi: %v", err)
		return
	}
	if !ok {
		return
	}
	idx := surveyIndex(ref.Question)
	if idx < 0 {
		return
	}
	q := prosSurvey[idx]
	ids := make([]string, 0, len(pa.OptionIDs))
	for _, i := range pa.OptionIDs {
		if i >= 0 && i < len(q.Options) {
			ids = append(ids, q.Options[i].ID)
		}
	}
	if len(ids) == 0 {
		return
	}
	first, err := w.Store.SaveSurveyAnswer(ctx, ref, ids)
	if err != nil {
		log.Printf("telegram: so'rovnoma javobi saqlanmadi: %v", err)
		return
	}
	if first {
		w.sendSurveyQuestion(ctx, ref, idx+1)
	}
}

// surveyTextReply — ochiq savolga matnli javob kutilayotgan bo'lsa saqlaydi va rahmat aytadi. true — javob qabul qilindi.
func (w *Worker) surveyTextReply(ctx context.Context, chatID int64, text string) bool {
	text = strings.TrimSpace(text)
	if text == "" || strings.HasPrefix(text, "/") {
		return false
	}
	ref, ok, err := w.Store.PendingSurveyText(ctx, chatID)
	if err != nil {
		log.Printf("telegram: so'rovnoma ochiq savoli o'qilmadi: %v", err)
		return false
	}
	if !ok {
		return false
	}
	if utf8.RuneCountInString(text) > 1000 {
		text = string([]rune(text)[:1000])
	}
	if _, err := w.Store.SaveSurveyAnswer(ctx, ref, text); err != nil {
		log.Printf("telegram: so'rovnoma javobi saqlanmadi: %v", err)
		return false
	}
	w.send(ctx, chatID, "🙏 "+st(surveyTexts["thanksTitle"], ref.Lang)+" "+st(surveyTexts["thanksText"], ref.Lang), removeKeyboard)
	return true
}
