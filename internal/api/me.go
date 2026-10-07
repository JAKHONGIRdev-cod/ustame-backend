package api

import (
	"net/http"
	"strings"
	"unicode/utf8"
)

// GET /api/me
func (s *Server) getMe(w http.ResponseWriter, r *http.Request) {
	u := s.requireUser(r.Context(), r)
	if u == nil {
		writeError(w, http.StatusUnauthorized, "AUTH_REQUIRED")
		return
	}
	writeJSON(w, http.StatusOK, publicUser(u))
}

// PATCH /api/me  { full_name?, active_role? }
func (s *Server) patchMe(w http.ResponseWriter, r *http.Request) {
	u := s.requireUser(r.Context(), r)
	if u == nil {
		writeError(w, http.StatusUnauthorized, "AUTH_REQUIRED")
		return
	}
	var body map[string]any
	if err := readJSON(w, r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_INPUT")
		return
	}

	fullName := u.FullName
	if v, ok := body["full_name"]; ok {
		fullName = strings.TrimSpace(str(v))
		if n := utf8.RuneCountInString(fullName); n < 2 || n > 60 {
			writeError(w, http.StatusBadRequest, "INVALID_NAME")
			return
		}
	}
	activeRole := u.ActiveRole
	if v, ok := body["active_role"]; ok {
		activeRole = str(v)
		if activeRole != "client" && activeRole != "provider" {
			writeError(w, http.StatusBadRequest, "INVALID_INPUT")
			return
		}
	}

	updated, err := scanUser(s.db.QueryRow(r.Context(), `
		update users set full_name = $1, active_role = $2 where id = $3::uuid
		returning `+userColumns, fullName, activeRole, u.ID))
	if err != nil {
		s.fail(w, "patch me", err)
		return
	}
	writeJSON(w, http.StatusOK, publicUser(updated))
}
