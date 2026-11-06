package cyrillic

import "testing"

func TestConvert(t *testing.T) {
	cases := map[string]string{
		"Uy ta'miri uchun ishonchli ustalar":                 "Уй таъмири учун ишончли усталар",
		"E'lon joylang, ustalar o'z narxini taklif qiladi":   "Эълон жойланг, усталар ўз нархини таклиф қилади",
		"Ro'yxatdan o'tmasdan ko'rish":                       "Рўйхатдан ўтмасдан кўриш",
		"{n} ta taklif":                                      "{n} та таклиф",
		"Ustame'dan foydalanib ko'ring":                      "Ustame'дан фойдаланиб кўринг",
		"Yo'q, yer, yuz, eshik, poeziya, g'isht, qo'ng'iroq": "Йўқ, ер, юз, эшик, поэзия, ғишт, қўнғироқ",
		"Pastdagi «📱 Raqamni yuborish» tugmasini bosing":     "Пастдаги «📱 Raqamni yuborish» тугмасини босинг",
		"Profil, kalkulyatori, sement, konditsioner":         "Профиль, калькулятори, цемент, кондиционер",
		"Havola: https://t.me/UstameBot va ustame.com":       "Ҳавола: https://t.me/UstameBot ва ustame.com",
		"SMS orqali kirish hozircha ishlamayapti":            "SMS орқали кириш ҳозирча ишламаяпти",
		"✅ Raqamingiz tasdiqlandi. Ilovaga qayting":          "✅ Рақамингиз тасдиқланди. Иловага қайтинг",
	}
	for in, want := range cases {
		if got := Convert(in); got != want {
			t.Errorf("Convert(%q)\n got: %q\nwant: %q", in, got, want)
		}
	}
}

func TestFor(t *testing.T) {
	if got := For("uz", "salom"); got != "salom" {
		t.Errorf("uz o'zgarmasligi kerak: %q", got)
	}
	if got := For("uzc", "salom"); got != "салом" {
		t.Errorf("uzc: %q", got)
	}
}
