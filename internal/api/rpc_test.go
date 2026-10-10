package api

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func decodeArg(t *testing.T, raw string) any {
	t.Helper()
	d := json.NewDecoder(strings.NewReader(raw))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestToArg(t *testing.T) {
	// Matnlar massivi — text[] parametri uchun (masalan, kasblar ro'yxati)
	got, err := toArg(decodeArg(t, `["Santexnik","Elektrik"]`))
	if err != nil || !reflect.DeepEqual(got, []string{"Santexnik", "Elektrik"}) {
		t.Fatalf("matnlar massivi: %#v, %v", got, err)
	}

	// Obyektlar massivi — jsonb parametri uchun JSON matn (bosqichlar rejasi)
	got, err = toArg(decodeArg(t, `[{"title":"Material","amount":180000},{"title":"Ish","amount":420000}]`))
	if err != nil {
		t.Fatal(err)
	}
	if s, ok := got.(string); !ok || s != `[{"amount":180000,"title":"Material"},{"amount":420000,"title":"Ish"}]` {
		t.Fatalf("obyektlar massivi JSON matn bo'lishi kerak: %#v", got)
	}

	got, err = toArg(decodeArg(t, `{"a":1}`))
	if err != nil || got != `{"a":1}` {
		t.Fatalf("obyekt: %#v, %v", got, err)
	}

	got, err = toArg(decodeArg(t, `150000`))
	if err != nil || got != int64(150000) {
		t.Fatalf("butun son: %#v, %v", got, err)
	}
}
