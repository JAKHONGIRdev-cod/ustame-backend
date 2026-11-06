// Package cyrillic — o'zbek lotin yozuvidan kirillga o'girish. Ilovadagi src/i18n/cyrillic.ts bilan bir xil
// qoidalar: kirill ("Ўзбекча") tanlagan foydalanuvchiga bildirishnoma va bot xabarlari kirillda boradi.
//
// O'zgarmaydi: {parametr}lar, havolalar, e-pochta, @nomlar, domenlar va keep dagi nomlar (Ustame, Telegram…).
package cyrillic

import (
	"regexp"
	"strings"
	"unicode"
)

var letters = map[rune]string{
	'a': "а", 'b': "б", 'c': "ц", 'd': "д", 'e': "е", 'f': "ф", 'g': "г", 'h': "ҳ", 'i': "и", 'j': "ж",
	'k': "к", 'l': "л", 'm': "м", 'n': "н", 'o': "о", 'p': "п", 'q': "қ", 'r': "р", 's': "с", 't': "т",
	'u': "у", 'v': "в", 'w': "в", 'x': "х", 'y': "й", 'z': "з",
}

const vowelsCyr = "аеёиоуўэюя"

// Lotincha qoladigan nomlar (so'z boshida bo'lsa, qo'shimchasi o'giriladi: Telegram'da → Telegram'да)
var keep = map[string]bool{}

func init() {
	for _, w := range []string{
		"Ustame", "UstaMe", "Telegram", "Google", "Play", "Android", "iPhone", "iOS", "Click", "Payme", "Uzum",
		"Paynet", "SMS", "PDF", "ID", "OK", "Face", "FaceID", "GPS", "JPG", "PNG", "WEBP", "Excel", "Start",
		"Instagram", "YouTube", "Facebook", "WhatsApp", "Eskiz", "MyID", "OneID", "Store", "Market", "Wi-Fi",
		"Gmail", "Expo", "STIR",
	} {
		keep[w] = true
	}
}

// Qoida bilan noto'g'ri chiqadigan so'zlar (kichik harfda)
var words = map[string]string{
	"kompyuter": "компьютер", "yanvar": "январь", "fevral": "февраль", "aprel": "апрель", "iyun": "июнь",
	"iyul": "июль", "sentabr": "сентябрь", "oktabr": "октябрь", "noyabr": "ноябрь", "dekabr": "декабрь",
	"aktiv": "актив", "internet": "интернет", "sertifikat": "сертификат", "aksiya": "акция",
	"profil": "профиль", "parol": "пароль", "mebel": "мебель", "kafel": "кафель", "kabel": "кабель",
}

// So'z boshi shunday bo'lsa, qo'shimchasi bilan ham shu yoziladi
var stems = [][2]string{{"kalkulyator", "калькулятор"}, {"kompyuter", "компьютер"}, {"sement", "цемент"}}

// Bot tugmasi lotincha yozilgan — ko'rsatmada ham aynan shunday qoladi
var keepPhrases = []string{"Raqamni yuborish"}

var digraphs = strings.NewReplacer(
	"tsiya", "ция", "tsion", "цион", "sh", "ш", "ch", "ч", "yo", "ё", "yu", "ю", "ya", "я", "ye", "е",
)

func cyrWord(lw string) string {
	// o' va g' — alohida harf; qolgan apostrof — tutuq belgisi (ъ)
	s := strings.NewReplacer("o'", "\x01", "g'", "\x02").Replace(lw)
	s = strings.ReplaceAll(s, "'", "\x03")
	s = digraphs.Replace(s)
	var b strings.Builder
	var prev rune
	for _, c := range s {
		var out string
		switch {
		case c == '\x01':
			out = "ў"
		case c == '\x02':
			out = "ғ"
		case c == '\x03':
			out = "ъ"
		case c == 'e':
			// so'z boshida va unlidan keyin — э (eshik → эшик)
			if prev == 0 || strings.ContainsRune(vowelsCyr, prev) || prev == 'ъ' {
				out = "э"
			} else {
				out = "е"
			}
		default:
			if l, ok := letters[c]; ok {
				out = l
			} else {
				out = string(c)
			}
		}
		b.WriteString(out)
		for _, r := range out {
			prev = r
		}
	}
	return b.String()
}

var brandSuffix = regexp.MustCompile(`^([A-Za-z-]+)'(.+)$`)

func convertWord(word string) string {
	if keep[word] {
		return word
	}
	if m := brandSuffix.FindStringSubmatch(word); m != nil && keep[m[1]] {
		return m[1] + "'" + convertWord(m[2])
	}
	lw := strings.ToLower(word)
	res, ok := words[lw]
	if !ok {
		res = cyrWord(lw)
		for _, st := range stems {
			if strings.HasPrefix(lw, st[0]) {
				res = st[1] + cyrWord(lw[len(st[0]):])
				break
			}
		}
	}
	if len(word) > 1 && word == strings.ToUpper(word) && strings.IndexFunc(word, unicode.IsLetter) >= 0 {
		return strings.ToUpper(res)
	}
	if r := []rune(word); unicode.IsUpper(r[0]) {
		rr := []rune(res)
		return strings.ToUpper(string(rr[0])) + string(rr[1:])
	}
	return res
}

// O'zgarmaydigan bo'laklar ({param}, havola, e-pochta, @nom, domen) yoki so'z
var token = regexp.MustCompile(`(\{\w+\}|https?://\S+|[\w.+-]+@[\w-]+\.[\w.]+|@\w+|\b[\w-]+\.(?:com|uz|ru|me|org|net)\b(?:/\S*)?)|([A-Za-z]+(?:'[A-Za-z]+)*'?)`)

var apostrophes = strings.NewReplacer("ʻ", "'", "ʼ", "'", "‘", "'", "’", "'", "`", "'")

// Convert lotincha o'zbek matnini kirillga o'giradi.
func Convert(text string) string {
	if text == "" {
		return text
	}
	src := apostrophes.Replace(text)
	var kept []string
	for _, p := range keepPhrases {
		if strings.Contains(src, p) {
			src = strings.ReplaceAll(src, p, "\x04"+string(rune('0'+len(kept)))+"\x04")
			kept = append(kept, p)
		}
	}
	out := token.ReplaceAllStringFunc(src, func(m string) string {
		sub := token.FindStringSubmatch(m)
		if sub[1] != "" {
			return m
		}
		w := sub[2]
		lower := strings.ToLower(w)
		if strings.HasSuffix(w, "'") && !strings.HasSuffix(lower, "o'") && !strings.HasSuffix(lower, "g'") {
			return convertWord(w[:len(w)-1]) + "'"
		}
		return convertWord(w)
	})
	for i, p := range kept {
		out = strings.ReplaceAll(out, "\x04"+string(rune('0'+i))+"\x04", p)
	}
	return out
}

// For tilga qarab: "uzc" (o'zbek kirill) bo'lsa o'giradi, aks holda matn o'zgarmaydi.
func For(lang, text string) string {
	if lang == "uzc" {
		return Convert(text)
	}
	return text
}
