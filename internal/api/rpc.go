package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// POST /api/rpc/{fn}  body: { "p_arg": qiymat, ... }
// sql/app.sql dagi funksiyani chaqiradi. Faqat `authenticated` rolga EXECUTE berilgan
// ilova funksiyalariga ruxsat (ro'yxat SQL grant'laridan olinadi). auth.uid() tranzaksiya
// ichida o'rnatiladigan request.jwt.claims orqali ishlaydi.

var (
	fnName    = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
	argName   = regexp.MustCompile(`^p_[a-z0-9_]+$`)
	errorCode = regexp.MustCompile(`^[A-Z][A-Z_]+$`)
)

var errorStatus = map[string]int{
	"AUTH_REQUIRED": http.StatusUnauthorized,
	"NOT_ALLOWED":   http.StatusForbidden,
	"NOT_ADMIN":     http.StatusForbidden,
	"NOT_FOUND":     http.StatusNotFound,
}

type returnKind int

const (
	returnsVoid returnKind = iota
	returnsJSON
	returnsOther
)

type funcCache struct {
	mu       sync.Mutex
	funcs    map[string]returnKind
	loadedAt time.Time
}

// get funksiya ruxsat etilganmi va nima qaytarishini aytadi. Ro'yxat birinchi so'rovda
// yuklanadi; noma'lum nom kelsa (masalan migratsiyadan keyin) daqiqada bir marta qayta yuklanadi.
func (c *funcCache) get(ctx context.Context, s *Server, name string) (returnKind, bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if kind, ok := c.funcs[name]; ok {
		return kind, true, nil
	}
	if c.funcs != nil && time.Since(c.loadedAt) < time.Minute {
		return 0, false, nil
	}
	rows, err := s.db.Query(ctx, `
		select distinct p.proname, p.prorettype::regtype::text
		from pg_proc p join pg_namespace n on n.oid = p.pronamespace
		where n.nspname = 'public'
		  and has_function_privilege('authenticated', p.oid, 'execute')
		  and p.prorettype <> 'trigger'::regtype
		  and p.proname !~ '^_'
		  -- pgcrypto kabi kengaytma funksiyalari emas, faqat ilovaning o'z funksiyalari
		  and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')`)
	if err != nil {
		return 0, false, err
	}
	defer rows.Close()
	funcs := map[string]returnKind{}
	for rows.Next() {
		var n, ret string
		if err := rows.Scan(&n, &ret); err != nil {
			return 0, false, err
		}
		switch ret {
		case "void":
			funcs[n] = returnsVoid
		case "json", "jsonb":
			funcs[n] = returnsJSON
		default:
			funcs[n] = returnsOther
		}
	}
	if err := rows.Err(); err != nil {
		return 0, false, err
	}
	c.funcs, c.loadedAt = funcs, time.Now()
	kind, ok := funcs[name]
	return kind, ok, nil
}

// toArg JSON qiymatini Postgres parametriga aylantiradi.
func toArg(v any) (any, error) {
	switch x := v.(type) {
	case nil, string, bool:
		return x, nil
	case json.Number:
		if i, err := x.Int64(); err == nil {
			return i, nil
		}
		return x.Float64()
	case []any:
		out := make([]string, len(x))
		for i, item := range x {
			s, ok := item.(string)
			if !ok {
				return nil, errors.New("array of non-strings")
			}
			out[i] = s
		}
		return out, nil
	}
	return nil, fmt.Errorf("unsupported %T", v)
}

func (s *Server) rpc(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	fn := r.PathValue("fn")
	if !fnName.MatchString(fn) {
		writeError(w, http.StatusNotFound, "NOT_FOUND")
		return
	}
	kind, ok, err := s.funcs.get(ctx, s, fn)
	if err != nil {
		s.fail(w, "rpc funcs", err)
		return
	}
	if !ok {
		writeError(w, http.StatusNotFound, "NOT_FOUND")
		return
	}

	u := s.requireUser(ctx, r)
	if u == nil {
		writeError(w, http.StatusUnauthorized, "AUTH_REQUIRED")
		return
	}

	var body map[string]any
	if err := readJSON(w, r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_INPUT")
		return
	}
	named := make([]string, 0, len(body))
	args := make([]any, 0, len(body))
	for name, v := range body {
		arg, err := toArg(v)
		if !argName.MatchString(name) || err != nil {
			writeError(w, http.StatusBadRequest, "INVALID_INPUT")
			return
		}
		args = append(args, arg)
		named = append(named, fmt.Sprintf("%s => $%d", name, len(args)))
	}
	call := fmt.Sprintf("public.%s(%s)", fn, strings.Join(named, ", "))
	claims, _ := json.Marshal(map[string]string{"sub": u.ID, "role": "authenticated"})

	tx, err := s.db.Begin(ctx)
	if err != nil {
		s.fail(w, "rpc begin", err)
		return
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `select set_config('request.jwt.claims', $1, true)`, string(claims)); err != nil {
		s.fail(w, "rpc claims", err)
		return
	}

	var result *string
	switch kind {
	case returnsVoid:
		_, err = tx.Exec(ctx, "select "+call, args...)
	case returnsJSON:
		err = tx.QueryRow(ctx, "select "+call+"::text", args...).Scan(&result)
	default:
		err = tx.QueryRow(ctx, "select to_jsonb("+call+")::text", args...).Scan(&result)
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && errorCode.MatchString(pgErr.Message) {
			status, ok := errorStatus[pgErr.Message]
			if !ok {
				status = http.StatusBadRequest
			}
			writeError(w, status, pgErr.Message)
			return
		}
		log.Printf("rpc %s: %v", fn, err)
		writeError(w, http.StatusInternalServerError, "SERVER_ERROR")
		return
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if result == nil {
		w.Write([]byte("null"))
	} else {
		w.Write([]byte(*result))
	}
}
