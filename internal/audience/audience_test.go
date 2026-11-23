package audience

import "testing"

func TestPrefix(t *testing.T) {
	cases := []struct {
		aud   string
		multi bool
		want  string
	}{
		{Admin, false, "🛡 Admin · "},
		{Admin, true, "🛡 Admin · "},
		{Provider, false, ""},
		{Client, false, ""},
		{Provider, true, "🔧 Usta · "},
		{Client, true, "🏠 Mijoz · "},
		{Shop, true, "🏪 Do'kon · "},
		{"", true, ""},
	}
	for _, c := range cases {
		if got := Prefix(c.aud, c.multi); got != c.want {
			t.Errorf("Prefix(%q, %v) = %q, kutilgan %q", c.aud, c.multi, got, c.want)
		}
	}
}
