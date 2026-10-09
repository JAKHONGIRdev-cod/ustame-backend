package api

import (
	"encoding/base64"
	"errors"
	"net/http"
	"regexp"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

// Rasmlar (vaqtincha Neon'dagi `files` jadvalida).
//   GET    /api/files?bucket=..&path=..     -> rasmning o'zi (ochiq, kirish shart emas)
//   GET    /api/files?bucket=..&prefix=..   -> ro'yxat [{ name, created_at }] (eng yangisi birinchi)
//   POST   /api/files  { bucket, path, content_type, data (base64) }  -> yuklash (upsert)
//   DELETE /api/files?bucket=..&path=..     -> o'chirish
// Yozish huquqi: avatars/<uid>/avatar.jpg, job-photos/<o'z e'loni id>/photo[-2..4].jpg,
// portfolio-photos/<uid>/<fayl>.

const (
	maxFileBytes = 3 << 20
	maxPortfolio = 9
)

var (
	buckets = []string{"avatars", "job-photos", "portfolio-photos"}
	// E'londa 4 tagacha rasm; nomlar qat'iy (sql/app.sql: _job_photos bilan bir xil)
	jobPhotoNames = []string{"photo.jpg", "photo-2.jpg", "photo-3.jpg", "photo-4.jpg"}
	imageTypes    = []string{"image/jpeg", "image/png", "image/webp"}
	filePath      = regexp.MustCompile(`^([0-9a-f-]{36})/([A-Za-z0-9._-]{1,64})$`)
	uuidLike      = regexp.MustCompile(`^[0-9a-f-]{36}$`)
)

// parsePath "<papka>/<nom>" ni ajratadi; bucket noma'lum yoki format noto'g'ri bo'lsa ok=false.
func parsePath(bucket, path string) (folder, name string, ok bool) {
	if !slices.Contains(buckets, bucket) {
		return "", "", false
	}
	m := filePath.FindStringSubmatch(path)
	if m == nil {
		return "", "", false
	}
	return m[1], m[2], true
}

func (s *Server) canWrite(r *http.Request, u *user, bucket, folder, name string) (bool, error) {
	switch bucket {
	case "avatars":
		return folder == u.ID && name == "avatar.jpg", nil
	case "portfolio-photos":
		return folder == u.ID, nil
	case "job-photos":
		if !slices.Contains(jobPhotoNames, name) {
			return false, nil
		}
		var clientID string
		err := s.db.QueryRow(r.Context(), `select client_id::text from jobs where id = $1::uuid`, folder).Scan(&clientID)
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return clientID == u.ID, err
	}
	return false, nil
}

func (s *Server) getFiles(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	bucket := q.Get("bucket")

	if q.Has("prefix") {
		prefix := q.Get("prefix")
		if !slices.Contains(buckets, bucket) || !uuidLike.MatchString(prefix) {
			writeError(w, http.StatusBadRequest, "INVALID_INPUT")
			return
		}
		rows, err := s.db.Query(r.Context(), `
			select substr(path, length($2) + 2), updated_at from files
			where bucket = $1 and path like $2 || '/%'
			order by updated_at desc`, bucket, prefix)
		if err != nil {
			s.fail(w, "files list", err)
			return
		}
		type item struct {
			Name      string    `json:"name"`
			CreatedAt time.Time `json:"created_at"`
		}
		list, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (item, error) {
			var it item
			return it, row.Scan(&it.Name, &it.CreatedAt)
		})
		if err != nil {
			s.fail(w, "files list", err)
			return
		}
		if list == nil {
			list = []item{}
		}
		writeJSON(w, http.StatusOK, list)
		return
	}

	path := q.Get("path")
	if _, _, ok := parsePath(bucket, path); !ok {
		writeError(w, http.StatusBadRequest, "INVALID_INPUT")
		return
	}
	var contentType string
	var data []byte
	err := s.db.QueryRow(r.Context(), `select content_type, data from files where bucket = $1 and path = $2`,
		bucket, path).Scan(&contentType, &data)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "NOT_FOUND")
		return
	}
	if err != nil {
		s.fail(w, "files get", err)
		return
	}
	w.Header().Set("Content-Type", contentType)
	// URL'da ?v=<vaqt> bo'lgani uchun uzoq keshlash xavfsiz
	w.Header().Set("Cache-Control", "public, max-age=86400")
	w.Write(data)
}

func (s *Server) uploadFile(w http.ResponseWriter, r *http.Request) {
	u := s.requireUser(r.Context(), r)
	if u == nil {
		writeError(w, http.StatusUnauthorized, "AUTH_REQUIRED")
		return
	}
	var body struct {
		Bucket      string `json:"bucket"`
		Path        string `json:"path"`
		ContentType string `json:"content_type"`
		Data        string `json:"data"`
	}
	if err := readJSON(w, r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "FILE_TOO_LARGE")
		return
	}
	folder, name, ok := parsePath(body.Bucket, body.Path)
	if !ok || !slices.Contains(imageTypes, body.ContentType) {
		writeError(w, http.StatusBadRequest, "INVALID_INPUT")
		return
	}
	data, err := base64.StdEncoding.DecodeString(body.Data)
	if err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_INPUT")
		return
	}
	if len(data) == 0 || len(data) > maxFileBytes {
		writeError(w, http.StatusBadRequest, "FILE_TOO_LARGE")
		return
	}
	// Turini baytlardan aniqlaymiz: rasm bo'lmagan narsa (masalan ilova faylni o'qiy olmay
	// yuborgan "File not found" matni) saqlanmaydi; tur ilova aytganidan farq qilsa — haqiqiysi.
	if detected := http.DetectContentType(data); slices.Contains(imageTypes, detected) {
		body.ContentType = detected
	} else {
		writeError(w, http.StatusBadRequest, "INVALID_IMAGE")
		return
	}
	allowed, err := s.canWrite(r, u, body.Bucket, folder, name)
	if err != nil {
		s.fail(w, "files upload", err)
		return
	}
	if !allowed {
		writeError(w, http.StatusForbidden, "NOT_ALLOWED")
		return
	}
	if body.Bucket == "portfolio-photos" {
		var count int
		if err := s.db.QueryRow(r.Context(), `select count(*)::int from files where bucket = $1 and path like $2 || '/%'`,
			body.Bucket, folder).Scan(&count); err != nil {
			s.fail(w, "files upload", err)
			return
		}
		if count >= maxPortfolio {
			writeError(w, http.StatusBadRequest, "TOO_MANY_PHOTOS")
			return
		}
	}
	if _, err := s.db.Exec(r.Context(), `
		insert into files (bucket, path, content_type, data) values ($1, $2, $3, $4)
		on conflict (bucket, path) do update
		  set content_type = excluded.content_type, data = excluded.data, updated_at = now()`,
		body.Bucket, body.Path, body.ContentType, data); err != nil {
		s.fail(w, "files upload", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) deleteFile(w http.ResponseWriter, r *http.Request) {
	u := s.requireUser(r.Context(), r)
	if u == nil {
		writeError(w, http.StatusUnauthorized, "AUTH_REQUIRED")
		return
	}
	q := r.URL.Query()
	bucket, path := q.Get("bucket"), q.Get("path")
	folder, name, ok := parsePath(bucket, path)
	if !ok {
		writeError(w, http.StatusBadRequest, "INVALID_INPUT")
		return
	}
	allowed, err := s.canWrite(r, u, bucket, folder, name)
	if err != nil {
		s.fail(w, "files delete", err)
		return
	}
	if !allowed {
		writeError(w, http.StatusForbidden, "NOT_ALLOWED")
		return
	}
	if _, err := s.db.Exec(r.Context(), `delete from files where bucket = $1 and path = $2`, bucket, path); err != nil {
		s.fail(w, "files delete", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
