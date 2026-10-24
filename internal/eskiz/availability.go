package eskiz

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"sync"
	"time"
)

// roleCacheTTL — Eskiz hisobining roli shuncha vaqt eslab qolinadi (har SMS so'rovida Eskiz'ga bormaymiz)
const roleCacheTTL = 10 * time.Minute

// availability — "kodli SMS yuborsa bo'ladimi" javobini vaqtincha eslab qoladi.
type availability struct {
	mu      sync.Mutex
	ok      bool
	checked time.Time
}

// get: eslab qolingan javob eskirmagan bo'lsa — o'sha, aks holda fetch() bilan yangilaydi.
// fetch xato bersa, SMS'ni to'smaymiz (Eskiz vaqtincha javob bermasa ham kirish ishlayversin).
func (a *availability) get(now time.Time, fetch func() (bool, error)) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.checked.IsZero() && now.Sub(a.checked) < roleCacheTTL {
		return a.ok
	}
	ok, err := fetch()
	if err != nil {
		log.Printf("eskiz: hisob holatini tekshirib bo'lmadi: %v", err)
		return true
	}
	a.ok, a.checked = ok, now
	return ok
}

// CanSendOTP — foydalanuvchiga kodli SMS haqiqatan yetib boradimi. Test rejimida (TestMode) yoki
// Eskiz hisobi hali "test" rolida bo'lsa (moderatsiyadan o'tgan shablon yo'q, odamga kod o'rniga
// "Bu Eskiz dan test" boradi) — yo'q: bunday paytda SMS so'ramaymiz, Telegram orqali kirish taklif qilinadi.
func (c *Client) CanSendOTP(ctx context.Context) bool {
	if c.TestMode {
		return false
	}
	return c.avail.get(time.Now(), func() (bool, error) {
		role, err := c.accountRole(ctx)
		if err != nil {
			return true, err
		}
		return role != "test", nil
	})
}

func (c *Client) accountRole(ctx context.Context) (string, error) {
	tok, err := c.token(ctx, false)
	if err != nil {
		return "", err
	}
	status, raw, err := c.getUser(ctx, tok)
	if err == nil && status == http.StatusUnauthorized {
		if tok, err = c.token(ctx, true); err == nil {
			status, raw, err = c.getUser(ctx, tok)
		}
	}
	if err != nil {
		return "", err
	}
	if status != http.StatusOK {
		return "", fmt.Errorf("Eskiz auth/user (%d): %s", status, raw)
	}
	return parseRole(raw)
}

func (c *Client) getUser(ctx context.Context, token string) (int, []byte, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/auth/user", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := c.HTTP.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	return res.StatusCode, raw, nil
}

// parseRole — javob {"data": {"role": …}} yoki {"role": …} ko'rinishida bo'lishi mumkin.
func parseRole(raw []byte) (string, error) {
	var out struct {
		Role string `json:"role"`
		Data struct {
			Role string `json:"role"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", err
	}
	if out.Data.Role != "" {
		return out.Data.Role, nil
	}
	if out.Role != "" {
		return out.Role, nil
	}
	return "", fmt.Errorf("Eskiz javobida rol yo'q: %.200s", raw)
}
