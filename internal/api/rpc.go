package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"maps"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
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
				// Obyektlar massivi (masalan bosqichlar rejasi) — jsonb parametr sifatida JSON matn
				return jsonArg(x)
			}
			out[i] = s
		}
		return out, nil
	case map[string]any:
		return jsonArg(x)
	}
	return nil, fmt.Errorf("unsupported %T", v)
}

// jsonArg murakkab qiymatni JSON matnga aylantiradi: Postgres uni funksiya parametrining turi (jsonb) bo'yicha o'qiydi.
func jsonArg(v any) (any, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return string(b), nil
}

// readOnly — faqat o'qiydigan funksiyalar (nomlash qoidasi bo'yicha): ular bildirishnoma yaratmaydi.
func readOnly(fn string) bool {
	for _, p := range []string{"get_", "find_", "search_", "admin_get_"} {
		if strings.HasPrefix(fn, p) {
			return true
		}
	}
	return false
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

	uid, tv, ok := s.tokenUser(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "AUTH_REQUIRED")
		return
	}

	var body map[string]any
	if err := readJSON(w, r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_INPUT")
		return
	}
	// Nomlar tartiblanadi: SQL matni har safar bir xil bo'lsa, pgx tayyorlangan so'rovni keshdan oladi
	// (Go map tartibi tasodifiy — aks holda har chaqiruvda qayta tayyorlash uchun qo'shimcha borib-kelish).
	names := slices.Sorted(maps.Keys(body))
	named := make([]string, 0, len(body))
	args := make([]any, 0, len(body))
	for _, name := range names {
		arg, err := toArg(body[name])
		if !argName.MatchString(name) || err != nil {
			writeError(w, http.StatusBadRequest, "INVALID_INPUT")
			return
		}
		args = append(args, arg)
		named = append(named, fmt.Sprintf("%s => $%d", name, len(args)))
	}
	call := fmt.Sprintf("public.%s(%s)", fn, strings.Join(named, ", "))

	// Foydalanuvchini tekshirish (auth.set_request_user) va funksiya bitta paketda ketadi: paket
	// yashirin tranzaksiyada bajariladi, shuning uchun bazaga bir marta borib-kelinadi (oldin 5 marta).
	// Token bekor qilingan bo'lsa set_request_user AUTH_REQUIRED tashlaydi va funksiya bajarilmaydi.
	var result *string
	scan := func(row pgx.Row) error { return row.Scan(&result) }
	b := &pgx.Batch{}
	b.Queue(`select auth.set_request_user($1::uuid, $2)`, uid, tv)
	switch kind {
	case returnsVoid:
		b.Queue("select "+call, args...)
	case returnsJSON:
		b.Queue("select "+call+"::text", args...).QueryRow(scan)
	default:
		b.Queue("select to_jsonb("+call+")::text", args...).QueryRow(scan)
	}
	start := time.Now()
	err = s.db.SendBatch(ctx, b).Close()
	w.Header().Set("Server-Timing", fmt.Sprintf("db;dur=%d", time.Since(start).Milliseconds()))
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

	s.Activity.Notify()
	if !readOnly(fn) {
		s.Outbox.Notify()
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if result == nil {
		w.Write([]byte("null"))
	} else {
		w.Write([]byte(*result))
	}
}
