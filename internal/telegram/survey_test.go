package telegram

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// surveyFake — so'rovnoma uchun soxta baza (fakeStore ichida)
type surveyFake struct {
	mu       sync.Mutex
	langs    map[string]string         // raqam -> users.lang
	done     map[string]bool           // ilovada javob bergan raqamlar
	refs     map[string]SurveyRef      // poll_id -> savol
	answered map[string]bool           // poll_id -> javob berilgan
	answers  map[string]map[string]any // raqam -> savol -> javob
}

func (s *fakeStore) sv() *surveyFake {
	if s.survey == nil {
		s.survey = &surveyFake{langs: map[string]string{}, done: map[string]bool{}, refs: map[string]SurveyRef{},
			answered: map[string]bool{}, answers: map[string]map[string]any{}}
	}
	return s.survey
}

func (s *fakeStore) SurveyLang(_ context.Context, phone, _ string) (string, bool, error) {
	f := s.sv()
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.done[phone] {
		return "uz", false, nil
	}
	for _, r := range f.refs {
		if r.Phone == phone {
			return "uz", false, nil
		}
	}
	lang := f.langs[phone]
	if lang == "" {
		lang = "uz"
	}
	return lang, true, nil
}

func (s *fakeStore) SaveSurveyQuestion(_ context.Context, r SurveyRef) error {
	f := s.sv()
	f.mu.Lock()
	defer f.mu.Unlock()
	f.refs[r.PollID] = r
	delete(f.answered, r.PollID)
	return nil
}

func (s *fakeStore) SurveyPoll(_ context.Context, id string) (SurveyRef, bool, error) {
	f := s.sv()
	f.mu.Lock()
	defer f.mu.Unlock()
	r, ok := f.refs[id]
	return r, ok, nil
}

func (s *fakeStore) PendingSurveyText(_ context.Context, chat int64) (SurveyRef, bool, error) {
	f := s.sv()
	f.mu.Lock()
	defer f.mu.Unlock()
	for id, r := range f.refs {
		if r.ChatID == chat && strings.HasPrefix(id, "t:") && !f.answered[id] {
			return r, true, nil
		}
	}
	return SurveyRef{}, false, nil
}

func (s *fakeStore) SaveSurveyAnswer(_ context.Context, r SurveyRef, v any) (bool, error) {
	f := s.sv()
	f.mu.Lock()
	defer f.mu.Unlock()
	first := !f.answered[r.PollID]
	f.answered[r.PollID] = true
	if f.answers[r.Phone] == nil {
		f.answers[r.Phone] = map[string]any{}
	}
	f.answers[r.Phone][r.Question] = v
	return first, nil
}

// pollTG — sendMessage va sendPoll'ni yozib oladigan soxta Telegram
type pollTG struct {
	mu    sync.Mutex
	n     int
	polls []sentPoll
	texts []string
	marks []map[string]any
}

type sentPoll struct {
	ID       string
	Question string
	Options  []string
	Multi    bool
}

func (t *pollTG) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var p map[string]any
	json.NewDecoder(r.Body).Decode(&p)
	t.mu.Lock()
	defer t.mu.Unlock()
	switch {
	case strings.HasSuffix(r.URL.Path, "/sendPoll"):
		t.n++
		id := "poll" + string(rune('0'+t.n))
		var opts []string
		for _, o := range p["options"].([]any) {
			opts = append(opts, o.(map[string]any)["text"].(string))
		}
		t.polls = append(t.polls, sentPoll{id, p["question"].(string), opts, p["allows_multiple_answers"] == true})
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "result": map[string]any{"poll": map[string]any{"id": id}}})
	case strings.HasSuffix(r.URL.Path, "/sendMessage"):
		t.texts = append(t.texts, p["text"].(string))
		m, _ := p["reply_markup"].(map[string]any)
		t.marks = append(t.marks, m)
		w.Write([]byte(`{"ok":true,"result":{}}`))
	default:
		w.Write([]byte(`{"ok":true,"result":{}}`))
	}
}

func newSurveyTest(t *testing.T) (*Worker, *pollTG, *fakeStore) {
	w, _, st := newTest(t)
	tg := &pollTG{}
	srv := httptest.NewServer(tg)
	t.Cleanup(srv.Close)
	w.TG = &Client{Token: "123:SECRET", BaseURL: srv.URL, HTTP: srv.Client()}
	return w, tg, st
}

func answer(poll string, opts ...int) Update {
	return Update{UpdateID: 2, PollAnswer: &PollAnswer{PollID: poll, User: &Sender{ID: 50}, OptionIDs: opts}}
}

// To'liq oqim: kirish matni -> 9 ta poll (har javobdan keyin keyingisi) -> ochiq savol -> rahmat
func TestSurveyFullFlow(t *testing.T) {
	w, tg, st := newSurveyTest(t)
	w.SurveyAfterLogin = time.Millisecond
	ctx := context.Background()

	w.startSurvey(ctx, 50, "998901234567")
	if len(tg.texts) != 1 || !strings.Contains(tg.texts[0], "so'rovnoma") || len(tg.polls) != 1 {
		t.Fatalf("kirish matni va 1-savol kutilgan: texts=%v polls=%d", tg.texts, len(tg.polls))
	}
	if !strings.HasPrefix(tg.polls[0].Question, "1/10. ") || len(tg.polls[0].Options) != 7 {
		t.Fatalf("1-savol: %+v", tg.polls[0])
	}

	// 1-8 savollar — bitta variant, 9-savol — bir nechta
	for i := 0; i < 9; i++ {
		poll := tg.polls[i]
		if i == 8 {
			if !poll.Multi || !strings.Contains(poll.Question, "3") {
				t.Fatalf("9-savol bir nechta tanlovli (3 tagacha) bo'lishi kerak: %+v", poll)
			}
			w.handleUpdate(ctx, answer(poll.ID, 0, 2))
		} else {
			w.handleUpdate(ctx, answer(poll.ID, 1))
		}
	}
	if len(tg.polls) != 9 {
		t.Fatalf("9 ta poll kutilgan, %d", len(tg.polls))
	}
	// 10-savol — ochiq, ForceReply bilan
	last := tg.texts[len(tg.texts)-1]
	if !strings.HasPrefix(last, "10/10. ") || tg.marks[len(tg.marks)-1]["force_reply"] != true {
		t.Fatalf("ochiq savol kutilgan: %q %v", last, tg.marks[len(tg.marks)-1])
	}
	w.handleUpdate(ctx, privateMsg(50, "Mijoz pulni bermay ketdi"))

	got := st.survey.answers["998901234567"]
	if a, _ := got["q1"].([]string); len(a) != 1 || a[0] != "electric" {
		t.Errorf("q1 = %v", got["q1"])
	}
	if a, _ := got["q9"].([]string); len(a) != 2 || a[0] != "nonpayment" || a[1] != "few_orders" {
		t.Errorf("q9 = %v", got["q9"])
	}
	if got["q10"] != "Mijoz pulni bermay ketdi" {
		t.Errorf("q10 = %v", got["q10"])
	}
	if !strings.HasPrefix(tg.texts[len(tg.texts)-1], "🙏") {
		t.Errorf("oxirida rahmat bo'lishi kerak: %q", tg.texts[len(tg.texts)-1])
	}
	// Endi oddiy matn — so'rovnoma emas (salomlashish javobi)
	n := len(st.survey.answers["998901234567"])
	w.handleUpdate(ctx, privateMsg(50, "salom"))
	if len(st.survey.answers["998901234567"]) != n {
		t.Error("so'rovnoma tugagach matn javob sifatida yozilmasligi kerak")
	}
}

// Ovozni o'zgartirsa — javob yangilanadi, lekin keyingi savol qayta yuborilmaydi
func TestSurveyVoteChangeNoDuplicate(t *testing.T) {
	w, tg, st := newSurveyTest(t)
	w.SurveyAfterLogin = time.Millisecond
	ctx := context.Background()
	w.startSurvey(ctx, 50, "998901234567")
	w.handleUpdate(ctx, answer(tg.polls[0].ID, 0))
	w.handleUpdate(ctx, answer(tg.polls[0].ID, 3))
	w.handleUpdate(ctx, answer(tg.polls[0].ID)) // ovozni qaytarib oldi — e'tiborsiz
	if len(tg.polls) != 2 {
		t.Fatalf("2 ta poll kutilgan, %d", len(tg.polls))
	}
	if a, _ := st.survey.answers["998901234567"]["q1"].([]string); len(a) != 1 || a[0] != "construction" {
		t.Errorf("q1 = %v", st.survey.answers["998901234567"]["q1"])
	}
}

// Avval boshlangan yoki ilovada javob bergan — qayta yuborilmaydi; ruscha foydalanuvchiga ruscha
func TestSurveyOnceAndLanguage(t *testing.T) {
	w, tg, st := newSurveyTest(t)
	ctx := context.Background()
	st.sv().done["998900000001"] = true
	w.startSurvey(ctx, 51, "998900000001")
	if len(tg.polls) != 0 || len(tg.texts) != 0 {
		t.Fatalf("ilovada javob berganga yuborilmasligi kerak: %v", tg.texts)
	}

	st.sv().langs["998900000002"] = "ru"
	w.startSurvey(ctx, 52, "998900000002")
	w.startSurvey(ctx, 52, "998900000002") // ikkinchi marta — yo'q
	if len(tg.polls) != 1 || !strings.Contains(tg.polls[0].Question, "В какой сфере") {
		t.Fatalf("ruscha 1 ta poll kutilgan: %+v", tg.polls)
	}
}

// Kirish tasdiqlangach so'rovnoma kechikish bilan o'zi boshlanadi; 0 — o'chiq
func TestSurveyScheduledAfterLogin(t *testing.T) {
	w, tg, st := newSurveyTest(t)
	w.OTPSecret = []byte("s")
	st.loginCodes["k1"] = true
	ctx := context.Background()

	w.SurveyAfterLogin = 0
	w.handleUpdate(ctx, privateMsg(60, "/start login_k1"))
	w.handleUpdate(ctx, contactMsg(60, 60, "998901112233"))
	time.Sleep(30 * time.Millisecond)
	tg.mu.Lock()
	if len(tg.polls) != 0 {
		t.Fatal("SurveyAfterLogin=0 bo'lsa so'rovnoma yuborilmasligi kerak")
	}
	tg.mu.Unlock()

	w.SurveyAfterLogin = 10 * time.Millisecond
	st.loginCodes["k2"] = true
	w.handleUpdate(ctx, privateMsg(61, "/start login_k2"))
	w.handleUpdate(ctx, contactMsg(61, 61, "998904445566"))
	deadline := time.Now().Add(2 * time.Second)
	for {
		tg.mu.Lock()
		n := len(tg.polls)
		tg.mu.Unlock()
		if n == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("kirishdan keyin so'rovnoma boshlanmadi")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
