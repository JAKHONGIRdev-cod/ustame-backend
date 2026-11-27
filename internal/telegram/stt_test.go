package telegram

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestOpenAISTTRequest(t *testing.T) {
	var got struct{ auth, model, lang, file string }
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got.auth = r.Header.Get("Authorization")
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Errorf("multipart: %v", err)
		}
		got.model, got.lang = r.FormValue("model"), r.FormValue("language")
		if f, _, err := r.FormFile("file"); err == nil {
			b, _ := io.ReadAll(f)
			got.file = string(b)
		}
		w.Write([]byte(`{"text":"  Kran oqyapti  "}`))
	}))
	defer srv.Close()

	s := &OpenAISTT{APIKey: "k1", URL: srv.URL, HTTP: srv.Client()}
	text, err := s.Transcribe(context.Background(), []byte("OGG"), "voice.ogg")
	if err != nil || text != "Kran oqyapti" {
		t.Fatalf("matn: %q %v", text, err)
	}
	if got.auth != "Bearer k1" || got.model != "gpt-4o-transcribe" || got.lang != "uz" || got.file != "OGG" {
		t.Fatalf("so'rov: %+v", got)
	}
}

func TestOpenAISTTError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		w.Write([]byte(`{"error":{"message":"bad key"}}`))
	}))
	defer srv.Close()
	s := &OpenAISTT{APIKey: "x", URL: srv.URL, HTTP: srv.Client()}
	if _, err := s.Transcribe(context.Background(), []byte("OGG"), "voice.ogg"); err == nil {
		t.Fatal("401 xato qaytarmadi")
	}
}
