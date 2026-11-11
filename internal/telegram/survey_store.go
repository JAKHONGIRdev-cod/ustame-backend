package telegram

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"
)

// Bot so'rovnomasi uchun baza amallari. Jadval: telegram_survey_polls (sql/app.sql), javoblar — survey_responses.

func (s *PgStore) SurveyLang(ctx context.Context, phone, survey string) (string, bool, error) {
	var lang string
	var start bool
	err := s.DB.QueryRow(ctx, `
		select coalesce((select lang from users where phone = $1), 'uz'),
		       not exists (select 1 from telegram_survey_polls where phone = $1 and survey = $2)
		       and not exists (select 1 from survey_responses r join users u on u.id = r.user_id
		                       where u.phone = $1 and r.survey = $2)`, phone, survey).Scan(&lang, &start)
	return lang, start, err
}

func (s *PgStore) SaveSurveyQuestion(ctx context.Context, r SurveyRef) error {
	_, err := s.DB.Exec(ctx, `
		insert into telegram_survey_polls (poll_id, chat_id, phone, survey, question, lang)
		values ($1, $2, $3, $4, $5, $6)
		on conflict (poll_id) do update set created_at = now(), answered_at = null`,
		r.PollID, r.ChatID, r.Phone, r.Survey, r.Question, r.Lang)
	return err
}

const surveyRefColumns = `poll_id, chat_id, phone, survey, question, lang`

func scanSurveyRef(row pgx.Row) (SurveyRef, bool, error) {
	var r SurveyRef
	err := row.Scan(&r.PollID, &r.ChatID, &r.Phone, &r.Survey, &r.Question, &r.Lang)
	if errors.Is(err, pgx.ErrNoRows) {
		return r, false, nil
	}
	return r, err == nil, err
}

func (s *PgStore) SurveyPoll(ctx context.Context, pollID string) (SurveyRef, bool, error) {
	return scanSurveyRef(s.DB.QueryRow(ctx, `select `+surveyRefColumns+` from telegram_survey_polls where poll_id = $1`, pollID))
}

func (s *PgStore) PendingSurveyText(ctx context.Context, chatID int64) (SurveyRef, bool, error) {
	return scanSurveyRef(s.DB.QueryRow(ctx, `
		select `+surveyRefColumns+` from telegram_survey_polls
		where chat_id = $1 and poll_id like 't:%' and answered_at is null and created_at > now() - interval '1 day'
		order by created_at desc limit 1`, chatID))
}

// SaveSurveyAnswer — savolni javob berilgan deb belgilaydi va javobni survey_responses.answers ga qo'shadi
// (ilovadagi format: tanlov — variant id'lari massivi, ochiq savol — satr). Foydalanuvchi hali yo'q bo'lsa
// (kirish tugamagan) javob faqat belgilanadi.
func (s *PgStore) SaveSurveyAnswer(ctx context.Context, r SurveyRef, value any) (bool, error) {
	val, err := json.Marshal(value)
	if err != nil {
		return false, err
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, `
		update telegram_survey_polls set answered_at = now() where poll_id = $1 and answered_at is null`, r.PollID)
	if err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `
		insert into survey_responses (user_id, survey, answers)
		select id, $2, jsonb_build_object($3::text, $4::jsonb) from users where phone = $1
		on conflict (user_id, survey) do update set answers = survey_responses.answers || excluded.answers`,
		r.Phone, r.Survey, r.Question, string(val)); err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, tx.Commit(ctx)
}
