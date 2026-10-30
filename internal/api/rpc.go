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
// ichida o'rnatiladigan request.jwt.claims orqali ishlaydi. `anon` rolga ham EXECUTE berilgan
// funksiyalarni (masalan saytdagi material narxlari) tokensiz mehmon ham chaqira oladi — auth.uid() null.

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

type funcInfo struct {
	kind returnKind
	anon bool // `anon` rolga ham ruxsat: kirmagan mehmon chaqira oladi
}

type funcCache struct {
	mu       sync.Mutex
	funcs    map[string]funcInfo
	loadedAt time.Time
}

// get funksiya ruxsat etilganmi va nima qaytarishini aytadi. Ro'yxat birinchi so'rovda
// yuklanadi; noma'lum nom kelsa (masalan migratsiyadan keyin) daqiqada bir marta qayta yuklanadi.
func (c *funcCache) get(ctx context.Context, s *Server, name string) (funcInfo, bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if info, ok := c.funcs[name]; ok {
		return info, true, nil
	}
	if c.funcs != nil && time.Since(c.loadedAt) < time.Minute {
		return funcInfo{}, false, nil
	}
	rows, err := s.db.Query(ctx, `
		select distinct p.proname, p.prorettype::regtype::text, has_function_privilege('anon', p.oid, 'execute')
		from pg_proc p join pg_namespace n on n.oid = p.pronamespace
		where n.nspname = 'public'
		  and has_function_privilege('authenticated', p.oid, 'execute')
		  and p.prorettype <> 'trigger'::regtype
		  and p.proname !~ '^_'
		  -- pgcrypto kabi kengaytma funksiyalari emas, faqat ilovaning o'z funksiyalari
		  and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')`)
	if err != nil {
		return funcInfo{}, false, err
	}
	defer rows.Close()
	funcs := map[string]funcInfo{}
	for rows.Next() {
		var n, ret string
		var anon bool
		if err := rows.Scan(&n, &ret, &anon); err != nil {
			return funcInfo{}, false, err
		}
		info := funcInfo{kind: returnsOther, anon: anon}
		switch ret {
		case "void":
			info.kind = returnsVoid
		case "json", "jsonb":
			info.kind = returnsJSON
		}
		funcs[n] = info
	}
	if err := rows.Err(); err != nil {
		return funcInfo{}, false, err
	}
	c.funcs, c.loadedAt = funcs, time.Now()
	info, ok := funcs[name]
	return info, ok, nil
}

// anonCache — mehmonlar chaqiradigan argumentsiz funksiyalar javobi (masalan get_material_catalog):
// sayt har ochilganda (botlar ham) baza uyg'onmasligi uchun bir necha daqiqa xotirada turadi.
// Faqat argumentsiz chaqiruvlar saqlanadi — kalitlar soni ochiq funksiyalar sonidan oshmaydi.
type anonCache struct {
	mu    sync.Mutex
	items map[string]anonEntry
}

type anonEntry struct {
	body *string
	at   time.Time
}

const anonCacheTTL = 5 * time.Minute

func (c *anonCache) get(fn string, now time.Time) (*string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.items[fn]
	if !ok || now.Sub(e.at) > anonCacheTTL {
		return nil, false
	}
	return e.body, true
}

func (c *anonCache) put(fn string, body *string, now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.items == nil {
		c.items = map[string]anonEntry{}
	}
	c.items[fn] = anonEntry{body: body, at: now}
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
	for _, p := range []string{"get_", "find_", "search_", "admin_get_", "admin_search_"} {
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
	info, ok, err := s.funcs.get(ctx, s, fn)
	if err != nil {
		s.fail(w, "rpc funcs", err)
		return
	}
	if !ok {
		writeError(w, http.StatusNotFound, "NOT_FOUND")
		return
	}
	kind := info.kind

	uid, tv, signedIn := s.tokenUser(r)
	if !signedIn && !info.anon {
		writeError(w, http.StatusUnauthorized, "AUTH_REQUIRED")
		return
	}
	if !signedIn && !s.anonLimit.allow(clientIP(r), time.Now()) {
		writeError(w, http.StatusTooManyRequests, "Juda ko'p so'rov. Keyinroq urinib ko'ring")
		return
	}

	var body map[string]any
	if err := readJSON(w, r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_INPUT")
		return
	}
	// Mehmonning argumentsiz chaqiruvi: javob keshda bo'lsa bazaga borilmaydi
	cacheable := !signedIn && len(body) == 0 && kind != returnsVoid
	if cacheable {
		if cached, ok := s.anonCache.get(fn, time.Now()); ok {
			writeRPCResult(w, cached)
			return
		}
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
	if signedIn {
		b.Queue(`select auth.set_request_user($1::uuid, $2)`, uid, tv)
	}
	switch kind {
	case returnsVoid:
		b.Queue("select "+call, args...)
	case returnsJSON:
		b.Queue("select "+call+"::text", args...).QueryRow(scan)
	default:
		b.Queue("select to_jsonb("+call+")::text", args...).QueryRow(scan)
	}
	// Admin amallari jurnali: o'zgartiruvchi admin_* chaqiruvi shu paketning o'zida yoziladi — funksiya xato
	// bersa (masalan admin emas) paket bekor bo'ladi va yozuv ham qolmaydi.
	if signedIn && strings.HasPrefix(fn, "admin_") && !readOnly(fn) {
		logArgs, _ := json.Marshal(body)
		b.Queue(`insert into public.admin_actions (admin_id, action, args) values ($1::uuid, $2, $3::jsonb)`,
			uid, fn, string(logArgs))
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
	if cacheable {
		s.anonCache.put(fn, result, time.Now())
	}
	writeRPCResult(w, result)
}

func writeRPCResult(w http.ResponseWriter, result *string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if result == nil {
		w.Write([]byte("null"))
	} else {
		w.Write([]byte(*result))
	}
}
